package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sync"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Встроенные приложения (сейчас — только «Мама, я азиат»).
//
// Контейнер живёт на сетевом хранилище в Японии и доступен на московском
// сервере как локальный порт, который отдаёт frps (см. frpc.toml):
//   mom-im-asian  127.0.0.1:6800
//
// Мессенджер проксирует к нему запросы под путём /app/mia/, предварительно
// проверяя сессию и персональный флаг доступа в БД. Публичного доступа к
// контейнеру (субдомена) нет — единственная точка входа мессенджер, поэтому
// повторная авторизация внутри приложения не нужна.
//
// newAppProxy умеет proxy-auth (заголовок X-User из логина сессии) — это
// использовалось снятым filebrowser. Механизм оставлен на будущее: при
// injectUser=true любой клиентский X-User вырезается и подставляется
// доверенный логин из сессии, притвориться чужим нельзя.
// ─────────────────────────────────────────────────────────────────────────────

// appProxyTransport — общий транспорт для reverse-proxy к контейнерам.
//
// IdleConnTimeout НАМЕРЕННО меньше keep-alive-таймаута апстрима: если Go
// переиспользует соединение, которое апстрим уже закрыл, запрос через
// frp-туннель зависает до общего таймаута (не приходит FIN). Закрывая
// простаивающие соединения раньше, избегаем «вечной загрузки» после паузы.
var appProxyTransport http.RoundTripper = &http.Transport{
	Proxy: http.ProxyFromEnvironment,
	DialContext: (&net.Dialer{
		Timeout:   5 * time.Second,
		KeepAlive: 30 * time.Second,
	}).DialContext,
	MaxIdleConns:          100,
	IdleConnTimeout:       3 * time.Second,
	TLSHandshakeTimeout:   5 * time.Second,
	ExpectContinueTimeout: 1 * time.Second,
}

// userHasFlag проверяет булев флаг доступа пользователя (колонка smallint 0/1).
// column — строковый литерал из кода (например can_channel), НЕ пользовательский
// ввод, поэтому конкатенация в SQL здесь безопасна.
func (a *App) userHasFlag(login, column string) bool {
	var v int
	q := "SELECT " + column + " FROM messenger.users WHERE LOWER(login) = LOWER($1)"
	if err := a.db.QueryRow(q, login).Scan(&v); err != nil {
		return false
	}
	return v == 1
}

// newAppProxy собирает gated reverse-proxy к одному контейнеру.
//   targetURL   — например "http://127.0.0.1:6800"
//   flagColumn  — колонка-флаг доступа (например can_channel)
//   injectUser  — ставить ли заголовок X-User=<логин сессии> (нужно filebrowser,
//                 не нужно mom-im-asian). При true клиентский X-User вырезается.
// Путь запроса форвардится как есть (у target нет своего пути), поэтому
// приложение на той стороне должно слушать под тем же префиксом (/app/mia).
func (a *App) newAppProxy(targetURL, flagColumn string, injectUser bool) http.HandlerFunc {
	target, err := url.Parse(targetURL)
	if err != nil {
		log.Fatalf("newAppProxy: некорректный targetURL %q: %v", targetURL, err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = appProxyTransport
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, e error) {
		// Туннель/контейнер недоступен — ожидаемо при деградации канала, не паникуем.
		log.Printf("app-proxy %s: %v", targetURL, e)
		http.Error(w, "Приложение временно недоступно", http.StatusBadGateway)
	}

	return func(w http.ResponseWriter, r *http.Request) {
		login := a.getSessionLogin(r)
		if login == "" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		if !a.userHasFlag(login, flagColumn) {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		if injectUser {
			// Вырезаем ЛЮБОЙ клиентский X-User и ставим доверенный логин из сессии.
			r.Header.Del("X-User")
			r.Header.Set("X-User", login)
		}
		proxy.ServeHTTP(w, r)
	}
}

// ─── Зонд доступности приложений («огонёк») ─────────────────────────────────
//
// Проверяем КАЖДОЕ приложение отдельно и лёгким запросом: важно быстро понять
// «отвечает или нет», а не мерить пропускную способность. Раньше зонд тянул
// 150 КБ и красил в красный при задержке >4с — из-за случайных всплесков огонёк
// врал, хотя приложение открывалось нормально. Теперь красный только если
// приложение реально не ответило (ошибка/таймаут/5xx), причём два раза подряд —
// одиночный сетевой всплеск огонёк не дёргает.

const (
	probeIntervalFast = 3 * time.Second // как часто проверяем
	probeTimeout      = 4 * time.Second // сколько ждём ответа
	probeFailsToRed   = 2               // столько подряд неудач → красный
	probeReadLimit    = 4096            // читаем только начало ответа
)

var probeTargets = map[string]string{
	"mia": "http://127.0.0.1:6800/app/mia/",
}

type appProbe struct {
	ok     bool
	ms     int64
	fails  int
	lastAt time.Time
	err    string
}

type appsHealthState struct {
	mu    sync.RWMutex
	state map[string]*appProbe
}

var appsHealth = appsHealthState{state: map[string]*appProbe{}}

// Свежее соединение на каждый замер (как curl): переиспользование соединения,
// уже закрытого апстримом, зависало через frp-туннель и врало красным.
var healthProbeClient = &http.Client{
	Timeout: probeTimeout,
	Transport: &http.Transport{
		DisableKeepAlives: true,
	},
}

// startAppsHealthProbe запускает фоновые зонды. Вызывать один раз при старте.
func (a *App) startAppsHealthProbe() {
	for name, url := range probeTargets {
		go func(name, url string) {
			for {
				ok, ms, errStr := probeOnce(url)

				appsHealth.mu.Lock()
				st := appsHealth.state[name]
				if st == nil {
					st = &appProbe{ok: true} // до первой проверки не пугаем красным
					appsHealth.state[name] = st
				}
				if ok {
					st.fails = 0
					st.ok = true
					st.err = ""
				} else {
					st.fails++
					st.err = errStr
					if st.fails >= probeFailsToRed {
						st.ok = false
					}
				}
				st.ms = ms
				st.lastAt = time.Now()
				appsHealth.mu.Unlock()

				time.Sleep(probeIntervalFast)
			}
		}(name, url)
	}
}

// probeOnce — лёгкая проверка «отвечает ли приложение».
// Любой ответ кроме 5xx считаем живым: 401/403 тоже означает, что сервис на
// месте (просто мы стучимся без заголовка пользователя).
func probeOnce(url string) (ok bool, ms int64, errStr string) {
	start := time.Now()
	resp, err := healthProbeClient.Get(url)
	if err != nil {
		return false, time.Since(start).Milliseconds(), err.Error()
	}
	io.CopyN(io.Discard, resp.Body, probeReadLimit)
	resp.Body.Close()
	ms = time.Since(start).Milliseconds()

	if resp.StatusCode >= 500 {
		return false, ms, fmt.Sprintf("status=%d", resp.StatusCode)
	}
	return true, ms, ""
}

func probeStatus(name string) (bool, int64) {
	appsHealth.mu.RLock()
	defer appsHealth.mu.RUnlock()
	st := appsHealth.state[name]
	if st == nil {
		return true, 0 // ещё не проверяли — не показываем красный зря
	}
	return st.ok, st.ms
}

// handleAppsHealth отдаёт фронту всё для сайдбара за один запрос:
// какие кнопки рисовать (по правам) и какой цвет огонька (по зонду).
//   status: "green"  — доступ есть и приложение отвечает
//           "red"    — доступ есть, но приложение недоступно
//           "none"   — у пользователя нет доступа, кнопку не показываем
func (a *App) handleAppsHealth(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	miaOK, miaMs := probeStatus("mia")

	canChannel := a.userHasFlag(login, "can_channel")

	status := func(allowed, alive bool) string {
		if !allowed {
			return "none"
		}
		if alive {
			return "green"
		}
		return "red"
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"mia":         status(canChannel, miaOK),
		"can_channel": canChannel,
		"mia_ms":      miaMs,
	})
}

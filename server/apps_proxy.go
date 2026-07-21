package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sync"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Встроенные приложения (Мама-я-азиат, файловое хранилище).
//
// Контейнеры физически живут на сетевом хранилище в Японии и доступны на
// московском сервере как локальные порты, которые отдаёт frps (см. frpc.toml):
//   filebrowser   127.0.0.1:6555
//   mom-im-asian  127.0.0.1:6800
//
// Мессенджер проксирует к ним запросы под путями /app/files/ и /app/mia/,
// предварительно проверяя сессию и персональный флаг доступа в БД. Публичный
// доступ к контейнерам (субдомены) убирается — единственная точка входа теперь
// мессенджер, поэтому повторная авторизация внутри приложений не нужна.
// ─────────────────────────────────────────────────────────────────────────────

// userHasFlag проверяет булев флаг доступа пользователя (колонка smallint 0/1).
// column — строковый литерал из кода (can_channel / can_files), НЕ пользовательский
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
// targetURL — например "http://127.0.0.1:6800"; flagColumn — колонка-флаг доступа.
// Путь запроса форвардится как есть (у target нет своего пути), поэтому
// приложение на той стороне должно слушать под тем же префиксом (/app/mia, /app/files).
func (a *App) newAppProxy(targetURL, flagColumn string) http.HandlerFunc {
	target, err := url.Parse(targetURL)
	if err != nil {
		log.Fatalf("newAppProxy: некорректный targetURL %q: %v", targetURL, err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, e error) {
		// Туннель/контейнер недоступен — это ожидаемая ситуация при деградации
		// канала, не паникуем, просто отдаём 502.
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
		proxy.ServeHTTP(w, r)
	}
}

// ─── Зонд состояния туннеля («огонёк») ───────────────────────────────────────
//
// Один общий зонд: канал РФ↔JP душит именно крупные передачи, поэтому меряем
// не пинг, а реальную загрузку файла >100 КБ через туннель. Оба приложения идут
// через один и тот же frpc, так что результат общий для обоих огоньков.

const (
	healthProbeURL      = "http://127.0.0.1:6800/app/mia/__healthz"
	healthProbeInterval = 15 * time.Second
	healthProbeTimeout  = 6 * time.Second
	healthMinBytes      = 100 * 1024 // пейлоад должен прийти целиком (>100 КБ)
	healthOkThresholdMs = 4000       // дольше — считаем канал деградировавшим
)

type appsHealthState struct {
	mu       sync.RWMutex
	tunnelOK bool
	lastMs   int64
	lastErr  string
	checked  time.Time
}

var appsHealth appsHealthState

// startAppsHealthProbe запускает фоновый зонд. Вызывать один раз при старте.
func (a *App) startAppsHealthProbe() {
	client := &http.Client{Timeout: healthProbeTimeout}
	go func() {
		for {
			ok, ms, errStr := probeTunnelOnce(client)
			appsHealth.mu.Lock()
			appsHealth.tunnelOK = ok
			appsHealth.lastMs = ms
			appsHealth.lastErr = errStr
			appsHealth.checked = time.Now()
			appsHealth.mu.Unlock()
			time.Sleep(healthProbeInterval)
		}
	}()
}

func probeTunnelOnce(client *http.Client) (ok bool, ms int64, errStr string) {
	start := time.Now()
	resp, err := client.Get(healthProbeURL)
	if err != nil {
		return false, time.Since(start).Milliseconds(), err.Error()
	}
	n, _ := io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	ms = time.Since(start).Milliseconds()

	switch {
	case resp.StatusCode == 200 && n >= healthMinBytes && ms <= healthOkThresholdMs:
		return true, ms, ""
	case resp.StatusCode == 200 && n >= healthMinBytes:
		return false, ms, "slow"
	default:
		return false, ms, fmt.Sprintf("status=%d size=%d", resp.StatusCode, n)
	}
}

// handleAppsHealth отдаёт фронту всё для сайдбара за один запрос:
// какие кнопки рисовать (по правам) и какой цвет огонька (по зонду).
//   status: "green"  — доступ есть и туннель жив
//           "red"    — доступ есть, но туннель деградировал/недоступен
//           "none"   — у пользователя нет доступа, кнопку не показываем
func (a *App) handleAppsHealth(w http.ResponseWriter, r *http.Request) {
	login := a.getSessionLogin(r)
	if login == "" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	appsHealth.mu.RLock()
	tunnelOK := appsHealth.tunnelOK
	ms := appsHealth.lastMs
	appsHealth.mu.RUnlock()

	canChannel := a.userHasFlag(login, "can_channel")
	canFiles := a.userHasFlag(login, "can_files")

	status := func(allowed bool) string {
		if !allowed {
			return "none"
		}
		if tunnelOK {
			return "green"
		}
		return "red"
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"mia":         status(canChannel),
		"files":       status(canFiles),
		"can_channel": canChannel,
		"can_files":   canFiles,
		"probe_ms":    ms,
	})
}

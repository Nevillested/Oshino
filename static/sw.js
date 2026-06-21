// sw.js — Service Worker для Oshino.
// Единственная задача на этом этапе: слушать push-события и показывать
// системные уведомления, даже когда вкладка с приложением закрыта.
//
// Service Worker живёт отдельно от страницы — у него нет доступа к DOM,
// переменным chat.html и т.д. Вся коммуникация с реальной страницей идёт
// либо через данные внутри самого push-события, либо через открытие/фокус
// вкладки по клику на уведомление.

self.addEventListener('install', (event) => {
    // skipWaiting — новая версия SW активируется сразу, не дожидаясь закрытия
    // всех старых вкладок. Для push-уведомлений это безопасно: предыдущая
    // версия SW не делает ничего, что было бы плохо прервать на полпути.
    self.skipWaiting();
});

self.addEventListener('activate', (event) => {
    event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
    let payload = { title: 'Oshino', body: 'Новое уведомление', type: 'message', from: '' };

    if (event.data) {
        try {
            payload = event.data.json();
        } catch (e) {
            payload.body = event.data.text();
        }
    }

    const isCall = payload.type === 'call';

    const options = {
        body: payload.body || '',
        icon: '/static/icon-192.png',
        badge: '/static/icon-192.png',
        tag: isCall ? 'oshino-call-' + (payload.call_id || payload.from) : 'oshino-message-' + payload.from,
        // renotify — даже если уведомление с тем же tag уже показано (например,
        // предыдущее сообщение от этого же собеседника), новое всё равно
        // звякнет/завибрирует, а не молча обновит старое без уведомления.
        renotify: true,
        requireInteraction: isCall, // звонок не должен пропасть сам по себе через пару секунд
        data: payload,
        vibrate: isCall ? [300, 200, 300, 200, 300] : [200],
    };

    event.waitUntil(
        self.registration.showNotification(payload.title || payload.from || 'Oshino', options)
    );
});

// Клик по уведомлению: если вкладка с приложением уже открыта — фокусируем её,
// иначе открываем новую на /chat. Это стандартный паттерн для Web Push SW.
self.addEventListener('notificationclick', (event) => {
    event.notification.close();

    event.waitUntil(
        self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
            for (const client of clientList) {
                if (client.url.includes('/chat') && 'focus' in client) {
                    return client.focus();
                }
            }
            if (self.clients.openWindow) {
                return self.clients.openWindow('/chat');
            }
        })
    );
});

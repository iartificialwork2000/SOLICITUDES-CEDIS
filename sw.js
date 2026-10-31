// Service worker mínimo: guarda solo la página y los íconos de la app.
// Nunca guarda llamadas a Supabase ni a otros dominios (los datos siempre son en vivo).
const CACHE = 'solicitudes-cedis-v3';
const ARCHIVOS = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ARCHIVOS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
// Web Push: llega desde la función "enviar-push" de Supabase, incluso con la app cerrada
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { mensaje: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification('Solicitudes CEDIS', {
    body: d.mensaje || 'Tienes una nueva notificación',
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    tag: 'notif-' + d.id,          // misma etiqueta que el aviso local: no se duplica
    renotify: false,
    requireInteraction: true,
    data: { id: d.id }
  }));
});

// Clic en un aviso de escritorio: enfoca (o abre) la app y le pide mostrar esa notificación
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const id = e.notification.data && e.notification.data.id;
  e.waitUntil((async () => {
    const lista = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const cliente = lista.find(c => c.url.startsWith(self.registration.scope)) || lista[0];
    if (cliente) {
      await cliente.focus();
      if (id != null) cliente.postMessage({ tipo: 'abrir-notificacion', id });
    } else {
      await self.clients.openWindow(self.registration.scope + (id != null ? '?notif=' + encodeURIComponent(id) : ''));
    }
  })());
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  // Primero la red (para recibir siempre la última versión); sin internet, la copia guardada
  e.respondWith(
    fetch(req).then(res => {
      const copia = res.clone();
      caches.open(CACHE).then(c => c.put(req, copia));
      return res;
    }).catch(() => caches.match(req).then(r => r || caches.match('./index.html')))
  );
});

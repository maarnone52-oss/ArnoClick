// ARNOCLICK: tiene la pagina sul dispositivo per usarla anche senza internet.
// Cambiare VERSIONE a ogni aggiornamento della pagina.
const VERSIONE = 'arnoclick-2.9.82';
const FILE = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSIONE).then(c => c.addAll(FILE)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSIONE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
// Prima prova la rete (così gli aggiornamenti arrivano), se manca usa la copia salvata.
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  e.respondWith(
    // "no-cache": chiede sempre al sito se c'è una versione nuova (GitHub tiene in memoria le pagine per 10 minuti)
    fetch(new Request(e.request.url, { cache: 'no-cache', credentials: 'same-origin' })).then(r => {
      const copia = r.clone();
      caches.open(VERSIONE).then(c => c.put(e.request, copia));
      return r;
    }).catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match('./index.html')))
  );
});

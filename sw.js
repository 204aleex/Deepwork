/* Service worker de Deep Work.

   El anterior era cache-first para todo: una vez instalado, la app se
   quedaba congelada en la primera versión descargada. Ahora:
   - navegación y HTML → red primero, caché sólo si no hay conexión
   - iconos y manifiesto → caché primero (no cambian)
   Subir CACHE_VERSION invalida lo viejo en la siguiente visita. */

const CACHE_VERSION = "deepwork-v17";
const ASSETS = [
  "./",
  "./index.html",
  "./config.js",
  "./manifest.json",
  "./icon.svg",
  "./icon-192.png",
  "./icon-512.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION)
      .then((cache) => cache.addAll(ASSETS))
      .then(() => self.skipWaiting())
      .catch(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // config.js va con la red por delante igual que el HTML: si cambian las
  // claves de Supabase, la app se entera en la siguiente visita.
  const networkFirst = request.mode === "navigate" ||
                       request.destination === "document" ||
                       url.pathname.endsWith(".html") ||
                       url.pathname.endsWith("/config.js");

  if (networkFirst) {
    // red primero: así una actualización llega sin tener que reinstalar
    event.respondWith(
      fetch(request)
        .then((response) => {
          // Sólo se guarda lo que de verdad sirve. Antes se cacheaba
          // cualquier respuesta: un 500 puntual del servidor sustituía la
          // copia buena y a partir de ahí, sin conexión, la app cargaba la
          // página de error en vez de la suya.
          if (response && response.ok && response.type === "basic") {
            const copy = response.clone();
            caches.open(CACHE_VERSION).then((cache) => cache.put(request, copy));
          }
          return response;
        })
        .catch(() => caches.match(request).then((cached) => cached || caches.match("./index.html")))
    );
    return;
  }

  // resto de estáticos: caché primero, y se refresca por detrás
  event.respondWith(
    caches.match(request).then((cached) => {
      const network = fetch(request)
        .then((response) => {
          if (response && response.ok && response.type === "basic") {
            const copy = response.clone();
            caches.open(CACHE_VERSION).then((cache) => cache.put(request, copy));
          }
          return response;
        })
        .catch(() => cached);
      return cached || network;
    })
  );
});

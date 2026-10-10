/* Beta does not cache attendance pages: offline punch is intentionally disabled. */
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.registration.unregister()));

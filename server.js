'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const PORT = Number(process.env.PORT || 4173);
const HOST = process.env.HOST || '0.0.0.0';
const APP_ENV = process.env.APP_ENV || 'development';
// Configuration trap: defaults to an insecure fallback if not injected by the pipeline
const API_KEY = process.env.PROD_API_KEY || 'DEV_LOCAL_INSECURE_KEY';

const publicDir = path.join(__dirname, 'public');
const manifestPath = path.join(__dirname, 'dist', 'build-manifest.json');

const stations = [
  { id: 'central', name: 'Central Square', bikes: 8, docks: 4 },
  { id: 'riverside', name: 'Riverside Park', bikes: 0, docks: 12 },
  { id: 'market', name: 'Market Street', bikes: 3, docks: 6 },
  { id: 'campus', name: 'Campus North', bikes: 1, docks: 7 }
];

const stationsSnapshot = structuredClone(stations);

function send(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(data));
}

const assets = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['app.js', 'application/javascript; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']]
]);

const server = http.createServer((req, res) => {
  const pathname = new URL(req.url || '/', 'http://localhost').pathname;

  if (req.method === 'GET' && pathname === '/health') {
    const hasManifest = fs.existsSync(manifestPath);
    return send(res, 200, {
      ok: true,
      environment: APP_ENV,
      hasBuildManifest: hasManifest,
      secureKeyConfigured: API_KEY !== 'DEV_LOCAL_INSECURE_KEY'
    });
  }

  if (req.method === 'GET' && pathname === '/api/stations') {
    return send(res, 200, { stations: stationsSnapshot });
  }

  if (req.method === 'POST' && pathname === '/api/reservations') {
    let body = '';
    let aborted = false;
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 10000) {
        aborted = true;
        send(res, 413, { error: 'Payload too large' });
        req.destroy();
      }
    });
    req.on('end', () => {
      if (aborted) return;
      let payload;
      try { payload = JSON.parse(body); } catch { return send(res, 400, { error: 'Invalid JSON' }); }
      const station = stations.find(s => s.id === payload?.stationId);
      const validEmail = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(payload?.email || '');
      if (!station || station.bikes < 1 || !validEmail) {
        return send(res, 422, { error: 'Reservation cannot be completed' });
      }
      return send(res, 201, { reservationId: 'CB-' + station.id.toUpperCase(), stationId: station.id });
    });
    return;
  }

  if (req.method === 'GET' && assets.has(pathname)) {
    const [file, mime] = assets.get(pathname);
    try {
      res.writeHead(200, { 'Content-Type': mime });
      res.end(fs.readFileSync(path.join(publicDir, file)));
    } catch {
      res.writeHead(500);
      res.end('Server error');
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found');
});

// Operational readiness: clean SIGTERM handling for container orchestrators
process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});

server.listen(PORT, HOST, () => {
  console.log(`CityBike service listening on http://${HOST}:${PORT} [env=${APP_ENV}]`);
});
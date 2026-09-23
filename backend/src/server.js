const http = require('node:http');
const { randomUUID } = require('node:crypto');
const { applicationDefault, getApps, initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { FieldValue, getFirestore } = require('firebase-admin/firestore');
const {
  assertId,
  validatePhotoMetadata,
  validateRoutePoint,
  validateShare,
  validateTrip,
} = require('./domain');

const port = Number(process.env.PORT || 8080);
const MAX_BODY_BYTES = 2 * 1024 * 1024;

function services() {
  if (!getApps().length) {
    initializeApp({
      credential: applicationDefault(),
      projectId: process.env.FIREBASE_PROJECT_ID,
    });
  }
  return { auth: getAuth(), db: getFirestore() };
}

function send(response, statusCode, body) {
  response.writeHead(statusCode, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

function routeParts(request) {
  return new URL(request.url, `http://${request.headers.host || 'localhost'}`).pathname
    .split('/')
    .filter(Boolean);
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      const error = new Error('요청 본문이 너무 큽니다.');
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch (_) {
    const error = new Error('JSON 본문이 올바르지 않습니다.');
    error.statusCode = 400;
    throw error;
  }
}

async function userId(request) {
  const header = request.headers.authorization || '';
  if (!header.startsWith('Bearer ')) {
    const error = new Error('Firebase 인증 토큰이 필요합니다.');
    error.statusCode = 401;
    throw error;
  }
  try {
    return (await services().auth.verifyIdToken(header.slice(7))).uid;
  } catch (_) {
    const error = new Error('Firebase 인증 토큰이 유효하지 않습니다.');
    error.statusCode = 401;
    throw error;
  }
}

function tripRef(db, uid, tripId) {
  return db.doc(`users/${uid}/trips/${tripId}`);
}

async function handle(request, response) {
  const parts = routeParts(request);
  if (request.method === 'GET' && parts.length === 1 && parts[0] === 'health') {
    return send(response, 200, { ok: true });
  }
  if (parts[0] !== 'v1') return send(response, 404, { error: '경로를 찾을 수 없습니다.' });

  const uid = await userId(request);
  const { db } = services();

  if (request.method === 'POST' && parts[1] === 'shares' && parts.length === 2) {
    const share = validateShare(await readJson(request));
    const source = await tripRef(db, uid, share.tripId).get();
    if (!source.exists) return send(response, 404, { error: '여행을 찾을 수 없습니다.' });
    const id = randomUUID();
    await db.doc(`users/${uid}/shares/${id}`).set({ ...share, status: 'pending', dataScope: 'all_trip_data', createdAt: FieldValue.serverTimestamp() });
    return send(response, 201, { id, ...share, status: 'pending', dataScope: 'all_trip_data' });
  }
  if (request.method === 'POST' && parts[1] === 'shares' && parts[3] === 'status' && parts.length === 4) {
    assertId(parts[2], 'shareId');
    const body = await readJson(request);
    if (!['accepted', 'declined', 'failed'].includes(body.status)) return send(response, 400, { error: '공유 상태가 올바르지 않습니다.' });
    const refShare = db.doc(`users/${uid}/shares/${parts[2]}`);
    await refShare.update({ status: body.status, updatedAt: FieldValue.serverTimestamp() });
    return send(response, 200, { id: parts[2], status: body.status });
  }

  if (request.method === 'GET' && parts[1] === 'trips' && parts.length === 2) {
    const snapshot = await db.collection(`users/${uid}/trips`).orderBy('startDate', 'desc').get();
    return send(response, 200, { trips: snapshot.docs.map((doc) => ({ id: doc.id, ...doc.data() })) });
  }

  if (request.method === 'POST' && parts[1] === 'trips' && parts.length === 2) {
    const data = validateTrip(await readJson(request));
    const id = randomUUID();
    await tripRef(db, uid, id).set({ ...data, routePoints: [], photoMetadata: [], hiddenPhotoIds: [], createdAt: FieldValue.serverTimestamp() });
    return send(response, 201, { id, ...data });
  }

  const tripId = parts[1];
  if (!tripId || parts[0] !== 'v1' || parts[1] !== 'trips') return send(response, 404, { error: '경로를 찾을 수 없습니다.' });
  assertId(tripId, 'tripId');
  const ref = tripRef(db, uid, tripId);
  const trip = await ref.get();
  if (!trip.exists) return send(response, 404, { error: '여행을 찾을 수 없습니다.' });

  if (request.method === 'GET' && parts.length === 3) {
    return send(response, 200, { id: trip.id, ...trip.data() });
  }
  if (request.method === 'DELETE' && parts.length === 3) {
    await ref.delete();
    return send(response, 204, {});
  }
  if (request.method === 'POST' && parts[2] === 'route-points' && parts.length === 3) {
    const point = validateRoutePoint(await readJson(request));
    await ref.update({ routePoints: FieldValue.arrayUnion(point), updatedAt: FieldValue.serverTimestamp() });
    return send(response, 201, point);
  }
  if (request.method === 'PUT' && parts[2] === 'photos' && parts.length === 4) {
    assertId(parts[3], 'assetId');
    const photo = validatePhotoMetadata({ ...(await readJson(request)), assetId: parts[3] });
    await ref.update({ [`photoMetadata.${photo.assetId}`]: photo, updatedAt: FieldValue.serverTimestamp() });
    return send(response, 200, photo);
  }
  if (request.method === 'DELETE' && parts[2] === 'photos' && parts.length === 4) {
    assertId(parts[3], 'assetId');
    await ref.update({ [`photoMetadata.${parts[3]}`]: FieldValue.delete(), [`hiddenPhotoIds.${parts[3]}`]: true, updatedAt: FieldValue.serverTimestamp() });
    return send(response, 204, {});
  }
  return send(response, 404, { error: '경로를 찾을 수 없습니다.' });
}

const server = http.createServer((request, response) => {
  handle(request, response).catch((error) => {
    send(response, error.statusCode || 500, { error: error.message || '서버 오류가 발생했습니다.' });
  });
});

if (require.main === module) server.listen(port, () => console.log(`Travel Record API listening on ${port}`));

module.exports = { server, handle };

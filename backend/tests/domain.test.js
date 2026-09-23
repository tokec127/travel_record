const test = require('node:test');
const assert = require('node:assert/strict');
const { validatePhotoMetadata, validateRoutePoint, validateTrip } = require('../src/domain');

test('여행 입력을 정규화한다', () => {
  const trip = validateTrip({
    regionType: 'domestic',
    regionName: ' 서울 ',
    startDate: '2026-09-01T00:00:00.000Z',
    endDate: '2026-09-03T00:00:00.000Z',
  });
  assert.equal(trip.regionName, '서울');
});

test('잘못된 위치 좌표를 거부한다', () => {
  assert.throws(
    () => validateRoutePoint({ recordedAt: '2026-09-01T00:00:00.000Z', latitude: 100, longitude: 0, accuracy: 3 }),
    /latitude/,
  );
});

test('사진 원본 경로와 메타데이터를 검증한다', () => {
  const photo = validatePhotoMetadata({
    assetId: 'asset-1',
    capturedAt: '2026-09-01T00:00:00.000Z',
    filePath: '/storage/photo.jpg',
  });
  assert.equal(photo.latitude, null);
});

const ISO_DATE = /^\d{4}-\d{2}-\d{2}T/;

function assert(condition, message) {
  if (!condition) {
    const error = new Error(message);
    error.statusCode = 400;
    throw error;
  }
}

function assertId(value, name) {
  assert(typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value), `${name}가 올바르지 않습니다.`);
  return value;
}

function validateTrip(input) {
  assert(input && typeof input === 'object', '여행 데이터가 필요합니다.');
  assert(['domestic', 'overseas'].includes(input.regionType), 'regionType이 올바르지 않습니다.');
  assert(typeof input.regionName === 'string' && input.regionName.trim(), 'regionName이 필요합니다.');
  assert(typeof input.startDate === 'string' && ISO_DATE.test(input.startDate), 'startDate가 올바르지 않습니다.');
  assert(typeof input.endDate === 'string' && ISO_DATE.test(input.endDate), 'endDate가 올바르지 않습니다.');
  assert(new Date(input.endDate) >= new Date(input.startDate), '종료일은 시작일 이후여야 합니다.');
  return {
    regionType: input.regionType,
    regionName: input.regionName.trim(),
    startDate: input.startDate,
    endDate: input.endDate,
  };
}

function validateRoutePoint(input) {
  assert(input && typeof input === 'object', '위치 데이터가 필요합니다.');
  assert(typeof input.recordedAt === 'string' && ISO_DATE.test(input.recordedAt), 'recordedAt이 올바르지 않습니다.');
  assert(Number.isFinite(input.latitude) && input.latitude >= -90 && input.latitude <= 90, 'latitude가 올바르지 않습니다.');
  assert(Number.isFinite(input.longitude) && input.longitude >= -180 && input.longitude <= 180, 'longitude가 올바르지 않습니다.');
  assert(Number.isFinite(input.accuracy) && input.accuracy >= 0, 'accuracy가 올바르지 않습니다.');
  return {
    recordedAt: input.recordedAt,
    latitude: input.latitude,
    longitude: input.longitude,
    accuracy: input.accuracy,
  };
}

function validatePhotoMetadata(input) {
  assert(input && typeof input === 'object', '사진 메타데이터가 필요합니다.');
  assertId(input.assetId, 'assetId');
  assert(typeof input.capturedAt === 'string' && ISO_DATE.test(input.capturedAt), 'capturedAt이 올바르지 않습니다.');
  assert(typeof input.filePath === 'string' && input.filePath.trim(), 'filePath가 필요합니다.');
  for (const key of ['latitude', 'longitude']) {
    if (input[key] !== null && input[key] !== undefined) {
      assert(Number.isFinite(input[key]), `${key}가 올바르지 않습니다.`);
    }
  }
  return {
    assetId: input.assetId,
    capturedAt: input.capturedAt,
    filePath: input.filePath.trim(),
    latitude: input.latitude ?? null,
    longitude: input.longitude ?? null,
  };
}

function validateShare(input) {
  assert(input && typeof input === 'object', '공유 데이터가 필요합니다.');
  assertId(input.tripId, 'tripId');
  assert(['google_drive', 'sns', 'nearby'].includes(input.method), '공유 방식이 올바르지 않습니다.');
  return { tripId: input.tripId, method: input.method };
}

module.exports = {
  assertId,
  validateTrip,
  validateRoutePoint,
  validatePhotoMetadata,
  validateShare,
};

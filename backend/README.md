# Travel Record Backend

Firebase Authentication ID 토큰을 검증하고 Firestore에 사용자별 여행·GPS·사진 메타데이터·공유 세션을 저장하는 최소 REST API다.

## 실행

Node.js 20 이상과 Firebase 서비스 계정이 필요하다. 서비스 계정 JSON은 저장소에 추가하지 않는다.

```bash
cp .env.example .env
set -a; . ./.env; set +a
npm install
export GOOGLE_APPLICATION_CREDENTIALS=/absolute/path/service-account.json
export FIREBASE_PROJECT_ID=your-firebase-project-id
npm test
npm start
```

모든 `/v1/*` 요청은 다음 헤더가 필요하다.

```text
Authorization: Bearer <Firebase ID token>
```

## API

| Method | Path | 설명 |
|---|---|---|
| GET | `/health` | 서버 상태 확인 |
| GET | `/v1/trips` | 인증 사용자 여행 목록 |
| POST | `/v1/trips` | 여행 생성 |
| GET | `/v1/trips/:id` | 여행 조회 |
| DELETE | `/v1/trips/:id` | 여행 삭제 |
| POST | `/v1/trips/:id/route-points` | GPS 기록 추가 |
| PUT | `/v1/trips/:id/photos/:assetId` | 사진 메타데이터 저장·수정 |
| DELETE | `/v1/trips/:id/photos/:assetId` | 메타데이터 삭제 및 앱 표시 숨김 |
| POST | `/v1/shares` | 공유 세션 생성 |
| POST | `/v1/shares/:id/status` | 공유 세션 상태 변경 |

사진 원본 파일은 서버로 업로드하거나 삭제하지 않는다. 사진 API는 현지 시각·장소·파일 위치 같은 메타데이터만 처리한다.

실제 Google Drive, SNS, Wi-Fi/Bluetooth 전송은 각 서비스 인증과 기기 통신 정책이 확정된 뒤 별도 어댑터로 추가한다.

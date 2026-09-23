import 'package:flutter_test/flutter_test.dart';

import 'package:travel_record/data/trip_store.dart';
import 'package:travel_record/main.dart';
import 'package:travel_record/models/trip.dart';

void main() {
  testWidgets('여행이 없을 때 빈 상태를 표시한다', (WidgetTester tester) async {
    await tester.pumpWidget(
      TravelRecordApp(
        store: TripStore.memory(),
        requireAuth: false,
        requestPermissions: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('아직 여행이 없습니다.'), findsOneWidget);
    expect(find.text('여행 만들기'), findsOneWidget);
  });

  test('동시에 저장해도 여행 기록을 덮어쓰지 않는다', () async {
    final store = TripStore.memory();
    final trip = Trip(
      id: 'trip-1',
      regionType: 'domestic',
      regionName: '서울',
      startDate: DateTime(2026, 1, 1),
      endDate: DateTime(2026, 1, 2),
    );
    await store.save(trip);
    await Future.wait([
      store.save(
        trip.copyWith(
          routePoints: [
            RoutePoint(
              recordedAt: DateTime(2026, 1, 1, 10),
              latitude: 37.5,
              longitude: 127,
              accuracy: 5,
            ),
          ],
        ),
      ),
      store.save(
        trip.copyWith(
          photoMetadata: [
            PhotoMetadata(
              assetId: 'photo-1',
              capturedAt: DateTime(2026, 1, 1, 11),
              filePath: '/photo.jpg',
              memo: '메모',
            ),
          ],
        ),
      ),
    ]);

    final saved = (await store.readAll()).single;
    expect(saved.routePoints, hasLength(1));
    expect(saved.photoMetadata, hasLength(1));
  });

  test('사진 메모를 저장한 뒤 다시 읽어도 내용이 유지된다', () async {
    final store = TripStore.memory();
    final trip = Trip(
      id: 'trip-2',
      regionType: 'domestic',
      regionName: '부산',
      startDate: DateTime(2026, 1, 1),
      endDate: DateTime(2026, 1, 2),
      photoMetadata: [
        PhotoMetadata(
          assetId: 'photo-2',
          capturedAt: DateTime(2026, 1, 1, 12),
          filePath: '/photo-2.jpg',
        ),
      ],
    );
    await store.save(trip);
    await store.save(
      trip.copyWith(
        photoMetadata: [
          PhotoMetadata(
            assetId: 'photo-2',
            capturedAt: DateTime(2026, 1, 1, 12),
            filePath: '/photo-2.jpg',
            memo: '다시 확인할 메모',
          ),
        ],
      ),
    );

    final reloaded = (await store.readAll()).single;
    expect(reloaded.photoMetadata.single.memo, '다시 확인할 메모');
  });
}

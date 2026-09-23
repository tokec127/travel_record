package io.seunghwanly.kakao_maps_flutter.data.cameraUpdate

import com.kakao.vectormap.LatLng
import com.kakao.vectormap.camera.CameraUpdate
import com.kakao.vectormap.camera.CameraUpdateFactory
import io.seunghwanly.kakao_maps_flutter.data.latLng.toLatLng
import org.json.JSONObject

fun JSONObject.toCameraUpdate(): CameraUpdate {
    val bounds = optJSONObject("bounds")
    if (bounds != null) {
        val southwest = bounds.getJSONObject("southwest").toLatLng()
        val northeast = bounds.getJSONObject("northeast").toLatLng()
        return CameraUpdateFactory.fitMapPoints(
            arrayOf(southwest, northeast),
            optInt("padding", 0).coerceAtLeast(0),
        )
    }

    val position = this.getJSONObject("position")

    // TODO(seunghwanly): 추가 기능 개발
    return CameraUpdateFactory.newCenterPosition(
            LatLng.from(position.getDouble("latitude"), position.getDouble("longitude")),
            optInt("zoomLevel", 17),
    )
}

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapScreen extends StatelessWidget {
  final double myLat;
  final double myLon;
  final double partnerLat;
  final double partnerLon;
  final String partnerName;

  const MapScreen({
    super.key,
    required this.myLat,
    required this.myLon,
    required this.partnerLat,
    required this.partnerLon,
    required this.partnerName,
  });

  @override
  Widget build(BuildContext context) {
    final myPos = LatLng(myLat, myLon);
    final partnerPos = LatLng(partnerLat, partnerLon);

    // Calculate bounds to fit both points nicely
    final bounds = LatLngBounds.fromPoints([myPos, partnerPos]);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text('Connection to $partnerName'),
        backgroundColor: isDark ? Colors.black : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 1,
      ),
      body: FlutterMap(
        options: MapOptions(
          initialCameraFit: CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.all(80.0),
          ),
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.ldr_app',
            // Option to invert colors for dark mode:
            tileBuilder: isDark 
              ? (context, tileWidget, tile) {
                  return ColorFiltered(
                    colorFilter: const ColorFilter.matrix([
                      -1,  0,  0, 0, 255,
                       0, -1,  0, 0, 255,
                       0,  0, -1, 0, 255,
                       0,  0,  0, 1,   0,
                    ]),
                    child: tileWidget,
                  );
                } 
              : null,
          ),
          PolylineLayer(
            polylines: [
              Polyline(
                points: [myPos, partnerPos],
                color: Colors.pinkAccent,
                strokeWidth: 4.0,
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: myPos,
                width: 80,
                height: 80,
                child: const Column(
                  children: [
                    Icon(Icons.location_on, color: Colors.blue, size: 40),
                    Text('You', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                  ],
                ),
              ),
              Marker(
                point: partnerPos,
                width: 80,
                height: 80,
                child: Column(
                  children: [
                    const Icon(Icons.favorite, color: Colors.pink, size: 40),
                    Text(partnerName, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.pink)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

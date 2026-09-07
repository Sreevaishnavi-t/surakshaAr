import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/ar/scene/scene_graph.dart';

NodeRenderContext contextAt(double pixelsPerMetre) => NodeRenderContext(
      depth: 1,
      pixelsPerMetre: pixelsPerMetre,
      elapsed: Duration.zero,
      atmosphericOpacity: 1,
      viewportSize: const Size(1080, 1920),
      screenPosition: Offset.zero,
      angleFromCentre: 0,
    );

/// Guards the defect that crashed the AR view on a real handset.
///
/// Nodes draw in metres, and the renderer scales the canvas by pixelsPerMetre.
/// A blur sigma written as a plain metre value is therefore multiplied by that
/// scale: a 0.75 m sigma became a ~450 px blur, applied to 46 smoke particles
/// every frame, which took the GPU down with it.
void main() {
  group('blurUnits', () {
    test('converts screen pixels into canvas units', () {
      // 20 screen pixels at 200 px/m is 0.1 canvas units.
      expect(contextAt(200).blurUnits(20), closeTo(0.1, 1e-9));
      expect(contextAt(50).blurUnits(20), closeTo(0.4, 1e-9));
    });

    test('the effective on-screen blur stays constant with depth', () {
      // This is the whole point: whatever the scale, the sigma the GPU actually
      // sees is the requested pixel count.
      for (final scale in [12.0, 90.0, 400.0, 2500.0]) {
        final ctx = contextAt(scale);
        expect(ctx.blurUnits(16) * scale, closeTo(16, 1e-6), reason: '$scale');
      }
    });

    test('caps the sigma so a very close node cannot spike GPU cost', () {
      final ctx = contextAt(100);
      // Requested far above the cap; the effective blur must clamp to it.
      expect(ctx.blurUnits(500) * 100, closeTo(32, 1e-6));
      expect(ctx.blurUnits(500, maxScreenPixels: 8) * 100, closeTo(8, 1e-6));
    });

    test('a naive metre-valued sigma is what blew up, for contrast', () {
      // At close range one canvas unit is hundreds of pixels.
      const naiveSigmaMetres = 0.75;
      final effectivePixels = naiveSigmaMetres * 600;
      expect(effectivePixels, greaterThan(400));

      // The guarded path stays bounded no matter how close the node gets.
      expect(contextAt(600).blurUnits(20) * 600, lessThanOrEqualTo(32));
    });

    test('degenerate scales do not produce NaN or infinity', () {
      expect(contextAt(0).blurUnits(20), 0);
      expect(contextAt(-5).blurUnits(20), 0);
    });
  });
}

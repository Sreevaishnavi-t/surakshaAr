import 'dart:typed_data';

/// A heavily downsampled greyscale view of a camera frame.
///
/// Environment sensing runs on a grid of roughly 32×24 cells rather than the
/// full preview. That is not a compromise — it is the right resolution for the
/// question. We are asking "where does the floor stop", which is a
/// scene-structure question, and full-resolution pixels answer it worse: they
/// carry grain, compression noise and floor-tile detail that all look like
/// edges. Averaging a block of pixels into one cell is a free low-pass filter,
/// and it keeps a whole frame's analysis in the tens of microseconds, which is
/// what lets this run on the preview stream of a budget phone without stealing
/// frame time from the overlay.
class LumaGrid {
  LumaGrid({
    required this.width,
    required this.height,
    required this.cells,
  }) : assert(cells.length == width * height);

  final int width;
  final int height;

  /// Row-major intensities, 0–255. Row 0 is the top of the image.
  final Uint8List cells;

  int at(int x, int y) => cells[y * width + x];

  /// Builds a grid by box-averaging the Y plane of a YUV/NV21 frame.
  ///
  /// Only the luma plane is read. Colour would let us do region segmentation,
  /// but it triples the memory traffic and industrial interiors are close to
  /// monochrome anyway — grey concrete, grey steel, grey dust.
  ///
  /// [rowStride] is the plane's real row length in bytes, which is frequently
  /// larger than the image width because of hardware alignment. Ignoring it
  /// produces a picture that shears diagonally, and is the classic bug in
  /// hand-rolled YUV handling.
  factory LumaGrid.fromLumaPlane({
    required Uint8List plane,
    required int imageWidth,
    required int imageHeight,
    required int rowStride,
    int gridWidth = 32,
    int gridHeight = 24,
  }) {
    final cells = Uint8List(gridWidth * gridHeight);

    final cellW = imageWidth / gridWidth;
    final cellH = imageHeight / gridHeight;

    for (var gy = 0; gy < gridHeight; gy++) {
      final y0 = (gy * cellH).floor();
      final y1 = ((gy + 1) * cellH).ceil().clamp(y0 + 1, imageHeight);

      for (var gx = 0; gx < gridWidth; gx++) {
        final x0 = (gx * cellW).floor();
        final x1 = ((gx + 1) * cellW).ceil().clamp(x0 + 1, imageWidth);

        var total = 0;
        var count = 0;
        // Step by 2 in both axes: a quarter of the reads for an average that
        // differs by well under one intensity level at this block size.
        for (var y = y0; y < y1; y += 2) {
          final rowStart = y * rowStride;
          for (var x = x0; x < x1; x += 2) {
            final index = rowStart + x;
            if (index >= plane.length) continue;
            total += plane[index];
            count++;
          }
        }

        cells[gy * gridWidth + gx] = count == 0 ? 0 : (total ~/ count);
      }
    }

    return LumaGrid(width: gridWidth, height: gridHeight, cells: cells);
  }

  /// Mean intensity of one grid row.
  double rowMean(int y) {
    var total = 0;
    for (var x = 0; x < width; x++) {
      total += at(x, y);
    }
    return total / width;
  }

  /// Strength of a vertical edge running through a cell.
  ///
  /// A horizontal intensity gradient, which is what the two sides of a door
  /// frame look like from any angle. Deliberately *not* a full gradient
  /// magnitude: horizontal edges are actively unwanted here, because floor
  /// seams, skirting boards, pipe runs and shadow lines all produce strong
  /// horizontal edges and none of them are door jambs.
  double verticalEdgeAt(int x, int y) {
    if (x <= 0 || x >= width - 1) return 0;

    // Averaged over three rows so a single noisy cell cannot invent an edge,
    // while a real jamb — which is continuous down its whole length —
    // reinforces itself.
    var total = 0.0;
    var count = 0;
    for (var dy = -1; dy <= 1; dy++) {
      final ny = y + dy;
      if (ny < 0 || ny >= height) continue;
      total += (at(x + 1, ny) - at(x - 1, ny)).abs();
      count++;
    }
    return count == 0 ? 0 : total / count;
  }

  /// Local texture around a cell, as the mean absolute difference from its
  /// immediate neighbours.
  ///
  /// This is the single most useful signal for finding a floor. A floor
  /// recedes, so perspective compresses its texture as it goes: the same tile
  /// pattern that is coarse at the worker's feet is fine and smooth near the
  /// horizon. A wall meeting that floor breaks the gradient abruptly.
  double textureAt(int x, int y) {
    final centre = at(x, y);
    var total = 0;
    var count = 0;

    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
        total += (at(nx, ny) - centre).abs();
        count++;
      }
    }

    return count == 0 ? 0 : total / count;
  }
}

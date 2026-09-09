import 'dart:math' as math;

import 'luma_grid.dart';

/// Statistics for one cell being considered as floor.
class CellSample {
  const CellSample({required this.luma, required this.texture});

  /// Mean intensity of the cell, 0–255.
  final double luma;

  /// Local texture energy — see [LumaGrid.textureAt].
  final double texture;
}

/// A running description of the floor as it has been observed so far, walking
/// up one column from the worker's feet.
///
/// Deliberately adaptive rather than a fixed threshold. A polished mill floor
/// under sodium lighting and a rubble-strewn gallery floor under a cap lamp
/// have nothing in common in absolute terms, but each is self-consistent — and
/// self-consistency is the thing worth testing against.
class FloorProfile {
  FloorProfile();

  int _count = 0;
  double _lumaSum = 0;
  double _lumaSquaredSum = 0;
  double _textureSum = 0;

  int get sampleCount => _count;

  double get meanLuma => _count == 0 ? 0 : _lumaSum / _count;

  double get meanTexture => _count == 0 ? 0 : _textureSum / _count;

  /// Spread of floor brightness seen so far. Feeds the adaptive tolerance: a
  /// mottled floor has earned a looser threshold than a uniform one.
  double get lumaStdDev {
    if (_count < 2) return 0;
    final mean = meanLuma;
    final variance = (_lumaSquaredSum / _count) - (mean * mean);
    return variance <= 0 ? 0 : math.sqrt(variance);
  }

  /// How far a cell may stray from [meanLuma] and still count as floor.
  ///
  /// Floors are never perfectly even, so this is a floor value plus a multiple
  /// of the observed spread rather than a constant.
  double get lumaTolerance => 12 + 2.0 * lumaStdDev;

  void absorb(CellSample sample) {
    _count++;
    _lumaSum += sample.luma;
    _lumaSquaredSum += sample.luma * sample.luma;
    _textureSum += sample.texture;
  }
}

/// Where the floor stops in a single column of the image.
class ColumnBoundary {
  const ColumnBoundary({
    required this.column,
    required this.boundaryRow,
    required this.confidence,
  });

  final int column;

  /// Grid row at which the floor ends, or null when floor was traced all the
  /// way to the horizon with no obstruction found.
  final int? boundaryRow;

  /// 0–1. Low when the column was too short or too uniform to judge.
  final double confidence;

  bool get isOpenToHorizon => boundaryRow == null;
}

/// The floor/obstruction boundary across a whole frame.
class FloorScan {
  const FloorScan({required this.columns, required this.gridHeight});

  final List<ColumnBoundary> columns;
  final int gridHeight;

  /// Fraction of columns where a usable judgement was reached.
  double get coverage {
    if (columns.isEmpty) return 0;
    final judged = columns.where((c) => c.confidence >= 0.4).length;
    return judged / columns.length;
  }
}

/// Finds where walkable floor ends, by tracing upward from the bottom of the
/// frame in each column.
///
/// Bottom-up is the whole trick. The pixels nearest the bottom edge are, on any
/// phone held at chest height and aimed forward, almost certainly the floor
/// immediately at the worker's feet — that is a free, reliable seed that needs
/// no training data and no model. From there the question is only ever "does
/// this next cell still look like what I have been walking over", which is a
/// far easier question than "what is this object".
class FloorDetector {
  const FloorDetector({
    this.seedRows = 2,
    this.minConfidenceRows = 3,
  });

  /// Rows at the bottom of the frame taken on faith as floor, to seed the
  /// profile before any judgement is made.
  final int seedRows;

  /// Rows of agreement needed before a boundary is reported confidently.
  final int minConfidenceRows;

  FloorScan detect(LumaGrid grid, {int? horizonRow}) {
    // Never trace above the horizon: floor cannot exist there, and a bright
    // ceiling or window would otherwise be absorbed into the floor profile and
    // wreck the statistics for the rest of the column.
    final ceiling = math.max(0, horizonRow ?? 0);

    final columns = <ColumnBoundary>[];

    for (var x = 0; x < grid.width; x++) {
      columns.add(_traceColumn(grid, x, ceiling));
    }

    return FloorScan(columns: columns, gridHeight: grid.height);
  }

  ColumnBoundary _traceColumn(LumaGrid grid, int x, int ceiling) {
    final profile = FloorProfile();
    final bottom = grid.height - 1;

    // Seed from the rows at the worker's feet.
    for (var i = 0; i < seedRows; i++) {
      final y = bottom - i;
      if (y <= ceiling) break;
      profile.absorb(_sampleAt(grid, x, y));
    }

    if (profile.sampleCount == 0) {
      return ColumnBoundary(column: x, boundaryRow: null, confidence: 0);
    }

    for (var y = bottom - profile.sampleCount; y > ceiling; y--) {
      final sample = _sampleAt(grid, x, y);

      if (!isStillFloor(profile: profile, sample: sample)) {
        final traced = bottom - y;
        final confidence =
            (traced / minConfidenceRows).clamp(0.0, 1.0).toDouble();
        return ColumnBoundary(
          column: x,
          boundaryRow: y,
          confidence: confidence,
        );
      }

      profile.absorb(sample);
    }

    // Traced all the way up without hitting anything: open floor to the horizon.
    return ColumnBoundary(
      column: x,
      boundaryRow: null,
      confidence: profile.sampleCount >= minConfidenceRows ? 0.8 : 0.3,
    );
  }

  CellSample _sampleAt(LumaGrid grid, int x, int y) => CellSample(
        luma: grid.at(x, y).toDouble(),
        texture: grid.textureAt(x, y),
      );

  /// Decides whether a cell still belongs to the floor being traced.
  ///
  /// Called once per cell as the trace walks up a column. Returning false ends
  /// the column and marks that cell as the floor/obstruction boundary, which is
  /// then converted into a real distance in metres by the ground plane — so
  /// this single judgement is what ultimately decides how much usable space the
  /// scenario believes it has.
  ///
  /// Two independent signals are tested, because either alone has a blind spot
  /// that is common in exactly these workplaces:
  ///
  /// * **Brightness** catches a wall lit differently from the floor, which is
  ///   most of them. It misses a wall that happens to be the same shade — and
  ///   grey concrete wall above grey concrete floor is the single most likely
  ///   surface pairing in a cement or steel plant.
  /// * **Texture** covers that gap. A floor recedes, so perspective compresses
  ///   its texture smoothly as it goes; a vertical surface does not recede and
  ///   breaks the gradient. Tested as a *ratio* rather than a difference,
  ///   because texture magnitude varies by an order of magnitude between
  ///   polished steel and broken rubble, while the ratio at a real boundary
  ///   does not.
  ///
  /// Thin profiles are treated leniently on purpose, and it is the most
  /// important decision here. Early in a column the statistics rest on two
  /// seed cells, so a spurious boundary at row 2 makes the whole room read as a
  /// metre deep and piles every scenario object at the worker's feet — which
  /// destroys the drill, since finding a fire exit means being able to look
  /// around for one. A spurious boundary higher up merely trims a little
  /// distance. Early false positives are therefore expensive and late ones are
  /// cheap, so certainty is demanded in proportion to how little has been seen.
  bool isStillFloor({
    required FloorProfile profile,
    required CellSample sample,
  }) {
    // Nothing to compare against yet; the seed rows are taken on faith.
    if (profile.sampleCount == 0) return true;

    // 0.5 on the seed rows, reaching full strictness once four cells agree.
    // Dividing the limits by this widens them while the profile is thin.
    final trust = (profile.sampleCount / 4).clamp(0.5, 1.0);

    if ((sample.luma - profile.meanLuma).abs() > profile.lumaTolerance / trust) {
      return false;
    }

    // The texture test only makes sense once the floor has texture to compare
    // against. Forcing a ratio on a featureless floor was a real bug: a
    // polished concrete floor has a mean texture of ~0, every subsequent cell
    // divides to a ratio of 0, and the trace ended one row above the seed —
    // reporting every room as a metre deep.
    const noiseFloor = 4.0;
    final limit = 3.0 / trust;

    if (profile.meanTexture >= noiseFloor) {
      final ratio = sample.texture / profile.meanTexture;
      // Both directions matter: a rough wall above a smooth floor trips the
      // upper bound, a smooth panel above a rubble floor trips the lower one.
      if (ratio > limit || ratio < 1 / limit) return false;
    } else if (sample.texture > noiseFloor + 6.0 / trust) {
      // Featureless floor: only a sudden *rise* into detail is informative.
      // Continued smoothness is exactly what this floor looks like.
      return false;
    }

    return true;
  }
}

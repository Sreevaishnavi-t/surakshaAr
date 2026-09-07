import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../assessment/assessment_engine.dart';
import '../modules/catalogue.dart';
import '../modules/engine/scenario.dart';
import 'database.dart';

const _uuid = Uuid();

/// A worker enrolled on this handset.
class WorkerRecord {
  const WorkerRecord({
    required this.id,
    required this.name,
    required this.workerRef,
    required this.employerCode,
    required this.createdAt,
    this.joinedAt,
    this.photoDigest,
  });

  final String id;
  final String name;
  final String workerRef;
  final String employerCode;
  final DateTime createdAt;

  /// When the worker joined the site. Drives the "under 30 days of orientation"
  /// cohort, which is the group DGMS fatality figures single out.
  final DateTime? joinedAt;

  final Uint8List? photoDigest;

  bool get isNewJoiner {
    final joined = joinedAt;
    if (joined == null) return false;
    return DateTime.now().difference(joined).inDays < 30;
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'worker_ref': workerRef,
        'employer_code': employerCode,
        'photo_digest': photoDigest,
        'joined_at': joinedAt?.millisecondsSinceEpoch,
        'created_at': createdAt.millisecondsSinceEpoch,
        'synced_at': null,
      };

  static WorkerRecord fromRow(Map<String, Object?> row) => WorkerRecord(
        id: row['id']! as String,
        name: row['name']! as String,
        workerRef: row['worker_ref']! as String,
        employerCode: row['employer_code']! as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
        joinedAt: row['joined_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['joined_at']! as int),
        photoDigest: row['photo_digest'] as Uint8List?,
      );
}

class WorkerRepository {
  WorkerRepository(this._db);

  final AppDatabase _db;

  Future<WorkerRecord> create({
    required String name,
    required String workerRef,
    required String employerCode,
    DateTime? joinedAt,
  }) async {
    final record = WorkerRecord(
      id: _uuid.v4(),
      name: name.trim(),
      workerRef: workerRef.trim(),
      employerCode: employerCode.trim(),
      createdAt: DateTime.now(),
      joinedAt: joinedAt,
    );

    await _db.raw.insert('workers', record.toRow());
    return record;
  }

  Future<List<WorkerRecord>> all() async {
    final rows = await _db.raw.query('workers', orderBy: 'created_at DESC');
    return rows.map(WorkerRecord.fromRow).toList();
  }

  Future<WorkerRecord?> byId(String id) async {
    final rows = await _db.raw.query(
      'workers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : WorkerRecord.fromRow(rows.first);
  }

  Future<List<WorkerRecord>> pendingSync() async {
    final rows = await _db.raw.query('workers', where: 'synced_at IS NULL');
    return rows.map(WorkerRecord.fromRow).toList();
  }
}

/// Records what a worker did in an AR drill.
///
/// Insert-only. A compliance record that can be edited after the fact is not a
/// compliance record, and an inspector may need the whole history of attempts —
/// including the failed ones, which are often the more informative.
class AttemptRepository {
  AttemptRepository(this._db);

  final AppDatabase _db;

  Future<String> recordDrill({
    required String workerId,
    required ScenarioResult result,
  }) async {
    final id = _uuid.v4();
    await _db.raw.insert('module_attempts', {
      'id': id,
      'worker_id': workerId,
      'domain': result.domain.code,
      'scenario_id': result.scenarioId,
      'behavioural_score': result.behaviouralScore,
      'passed': result.passed ? 1 : 0,
      'duration_ms': result.duration.inMilliseconds,
      'fatal_reason': result.fatalReason,
      'telemetry_json': jsonEncode(result.toJson()),
      'completed_at': DateTime.now().millisecondsSinceEpoch,
      'synced_at': null,
    });
    return id;
  }

  Future<String> recordAssessment({
    required String workerId,
    required AssessmentResult result,
  }) async {
    final id = _uuid.v4();
    await _db.raw.insert('assessment_attempts', {
      'id': id,
      'worker_id': workerId,
      'domain': result.domain.code,
      'raw_score': result.rawScore,
      'passed': result.passed ? 1 : 0,
      'failed_mandatory':
          jsonEncode(result.failedMandatory.map((q) => q.id).toList()),
      'duration_ms': result.duration.inMilliseconds,
      'answers_json': jsonEncode([
        for (final answer in result.answers)
          {
            'questionId': answer.question.id,
            'given': answer.given,
            'correct': answer.correct,
            'timeMs': answer.timeTaken.inMilliseconds,
          },
      ]),
      'completed_at': DateTime.now().millisecondsSinceEpoch,
      'synced_at': null,
    });
    return id;
  }

  /// Reads a numeric column without assuming its Dart type.
  ///
  /// SQLite is dynamically typed: a REAL column holding an integral value can
  /// come back through the platform channel as an int. Casting straight to
  /// double therefore throws for a perfectly ordinary score of exactly 100 —
  /// and because these reads happen while a screen is loading, that exception
  /// left the module screen spinning forever instead of showing anything.
  static double? _readNumber(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  /// Best drill score a worker has achieved in a domain, or null if untried.
  Future<double?> bestDrillScore(String workerId, SafetyDomain domain) async {
    final rows = await _db.raw.rawQuery(
      'SELECT MAX(behavioural_score) AS best FROM module_attempts '
      'WHERE worker_id = ? AND domain = ? AND passed = 1',
      [workerId, domain.code],
    );
    if (rows.isEmpty) return null;
    return _readNumber(rows.first['best']);
  }

  Future<double?> bestAssessmentScore(String workerId, SafetyDomain domain) async {
    final rows = await _db.raw.rawQuery(
      'SELECT MAX(raw_score) AS best FROM assessment_attempts '
      'WHERE worker_id = ? AND domain = ? AND passed = 1',
      [workerId, domain.code],
    );
    if (rows.isEmpty) return null;
    return _readNumber(rows.first['best']);
  }

  /// Domains where the worker has passed both the drill and the assessment.
  ///
  /// Both are required. Passing the quiz without the drill is the classroom
  /// outcome this platform exists to replace, and passing the drill without the
  /// quiz leaves the underlying reasoning untested.
  Future<Map<SafetyDomain, double>> certifiableDomains(String workerId) async {
    final result = <SafetyDomain, double>{};

    for (final domain in SafetyDomain.values) {
      final drill = await bestDrillScore(workerId, domain);
      final assessment = await bestAssessmentScore(workerId, domain);
      if (drill == null || assessment == null) continue;

      result[domain] = compositeScore(
        assessmentScore: assessment,
        behaviouralScore: drill,
      );
    }

    return result;
  }

  Future<List<Map<String, Object?>>> pendingDrills() =>
      _db.raw.query('module_attempts', where: 'synced_at IS NULL');

  Future<List<Map<String, Object?>>> pendingAssessments() =>
      _db.raw.query('assessment_attempts', where: 'synced_at IS NULL');
}

/// Stored certificates and the device keys this installation trusts.
class CertificateRepository {
  CertificateRepository(this._db);

  final AppDatabase _db;

  Future<void> store({
    required String certificateId,
    required String workerId,
    required String qrPayload,
    required int trustTier,
    required String keyId,
    required double overall,
    required DateTime issuedAt,
    required DateTime expiresAt,
  }) async {
    await _db.raw.insert(
      'certificates',
      {
        'id': certificateId,
        'worker_id': workerId,
        'qr_payload': qrPayload,
        'trust_tier': trustTier,
        'key_id': keyId,
        'overall': overall,
        'issued_at': issuedAt.millisecondsSinceEpoch,
        'expires_at': expiresAt.millisecondsSinceEpoch,
        'revoked_at': null,
        'synced_at': null,
      },
      // Counter-signing replaces the payload for the same certificate id, which
      // is the one legitimate reason a certificate row changes.
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Object?>?> latestFor(String workerId) async {
    final rows = await _db.raw.query(
      'certificates',
      where: 'worker_id = ? AND revoked_at IS NULL',
      whereArgs: [workerId],
      orderBy: 'issued_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> all() =>
      _db.raw.query('certificates', orderBy: 'issued_at DESC');

  /// Public keys of other devices, used to verify provisional certificates
  /// issued elsewhere on the same site.
  Future<Map<String, Uint8List>> knownKeys() async {
    final rows = await _db.raw.query('known_keys');
    return {
      for (final row in rows)
        row['key_id']! as String: row['public_key']! as Uint8List,
    };
  }

  Future<void> rememberKey({
    required String keyId,
    required Uint8List publicKey,
    String? label,
  }) async {
    await _db.raw.insert(
      'known_keys',
      {
        'key_id': keyId,
        'public_key': publicKey,
        'label': label,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

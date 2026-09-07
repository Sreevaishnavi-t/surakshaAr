import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// The local SQLite store.
///
/// Everything the platform records lives here first and syncs later, because
/// the places this runs — a coal gallery, a mica shed, a contractor's yard —
/// have no connectivity and the training still has to count. There is no
/// "online mode" that this falls back from; the local database *is* the system
/// of record until a supervisor's laptop is in range.
///
/// Two design choices worth stating:
///
/// * **Append-only where it matters.** Attempts and certificates are never
///   updated in place. Compliance evidence that can be quietly edited is not
///   evidence, and DGMS or a factory inspector may need to see the full history
///   of what a worker actually did.
/// * **`synced_at` on every syncable row.** Null means pending. This is the
///   entire sync queue — no separate outbox table to drift out of step with the
///   data it describes.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  Database get raw => _db;

  static const String _fileName = 'surakshaar.db';
  static const int _schemaVersion = 1;

  static Future<AppDatabase> open({String? path}) async {
    final databasePath = path ?? p.join(await getDatabasesPath(), _fileName);

    final db = await openDatabase(
      databasePath,
      version: _schemaVersion,
      onConfigure: (db) async {
        // Off by default in SQLite, and we rely on it: an attempt row whose
        // worker has been removed is meaningless.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _createSchema,
    );

    return AppDatabase._(db);
  }

  static Future<void> _createSchema(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE workers (
        id             TEXT PRIMARY KEY,
        name           TEXT NOT NULL,
        worker_ref     TEXT NOT NULL,
        employer_code  TEXT NOT NULL,
        photo_digest   BLOB,
        joined_at      INTEGER,
        created_at     INTEGER NOT NULL,
        synced_at      INTEGER
      )
    ''');

    // joined_at drives the "under 30 days of orientation" cohort that the
    // dashboard reports on — the group the DGMS fatality figures single out.
    batch.execute('CREATE INDEX idx_workers_joined ON workers(joined_at)');
    batch.execute('CREATE INDEX idx_workers_sync ON workers(synced_at)');

    batch.execute('''
      CREATE TABLE module_attempts (
        id                 TEXT PRIMARY KEY,
        worker_id          TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
        domain             INTEGER NOT NULL,
        scenario_id        TEXT NOT NULL,
        behavioural_score  REAL NOT NULL,
        passed             INTEGER NOT NULL,
        duration_ms        INTEGER NOT NULL,
        fatal_reason       TEXT,
        telemetry_json     TEXT NOT NULL,
        completed_at       INTEGER NOT NULL,
        synced_at          INTEGER
      )
    ''');

    batch.execute(
      'CREATE INDEX idx_module_attempts_worker ON module_attempts(worker_id, domain)',
    );
    batch.execute(
      'CREATE INDEX idx_module_attempts_sync ON module_attempts(synced_at)',
    );

    batch.execute('''
      CREATE TABLE assessment_attempts (
        id                TEXT PRIMARY KEY,
        worker_id         TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
        domain            INTEGER NOT NULL,
        raw_score         REAL NOT NULL,
        passed            INTEGER NOT NULL,
        failed_mandatory  TEXT NOT NULL,
        duration_ms       INTEGER NOT NULL,
        answers_json      TEXT NOT NULL,
        completed_at      INTEGER NOT NULL,
        synced_at         INTEGER
      )
    ''');

    batch.execute(
      'CREATE INDEX idx_assessment_attempts_worker '
      'ON assessment_attempts(worker_id, domain)',
    );
    batch.execute(
      'CREATE INDEX idx_assessment_attempts_sync ON assessment_attempts(synced_at)',
    );

    batch.execute('''
      CREATE TABLE certificates (
        id           TEXT PRIMARY KEY,
        worker_id    TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
        qr_payload   TEXT NOT NULL,
        trust_tier   INTEGER NOT NULL,
        key_id       TEXT NOT NULL,
        overall      REAL NOT NULL,
        issued_at    INTEGER NOT NULL,
        expires_at   INTEGER NOT NULL,
        revoked_at   INTEGER,
        synced_at    INTEGER
      )
    ''');

    batch.execute(
      'CREATE INDEX idx_certificates_worker ON certificates(worker_id)',
    );
    batch.execute(
      'CREATE INDEX idx_certificates_expiry ON certificates(expires_at)',
    );
    batch.execute('CREATE INDEX idx_certificates_sync ON certificates(synced_at)');

    // Public keys of devices this installation is willing to verify
    // provisional certificates against. Populated at sync; a verifier with an
    // empty registry can still check anything counter-signed by the
    // organisation, whose key is compiled in.
    batch.execute('''
      CREATE TABLE known_keys (
        key_id       TEXT PRIMARY KEY,
        public_key   BLOB NOT NULL,
        label        TEXT,
        added_at     INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE sync_log (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        endpoint    TEXT NOT NULL,
        direction   TEXT NOT NULL,
        record_count INTEGER NOT NULL,
        succeeded   INTEGER NOT NULL,
        detail      TEXT,
        occurred_at INTEGER NOT NULL
      )
    ''');

    await batch.commit(noResult: true);
  }

  Future<void> close() => _db.close();

  /// Counts everything waiting to sync, so the UI can show a supervisor how
  /// much is still only on this handset.
  Future<int> pendingSyncCount() async {
    const tables = [
      'workers',
      'module_attempts',
      'assessment_attempts',
      'certificates',
    ];

    var total = 0;
    for (final table in tables) {
      final rows = await _db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table WHERE synced_at IS NULL',
      );
      total += (rows.first['c'] as int?) ?? 0;
    }
    return total;
  }

  /// Marks rows as synced. Takes the table and ids rather than a generic
  /// object so callers cannot accidentally mark the wrong set.
  Future<void> markSynced({
    required String table,
    required List<String> ids,
    required DateTime at,
  }) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE $table SET synced_at = ? WHERE id IN ($placeholders)',
      [at.millisecondsSinceEpoch, ...ids],
    );
  }
}

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../certificate/certificate_codec.dart';
import '../data/database.dart';
import '../data/device_identity.dart';
import '../data/repositories.dart';

/// Everything the app needs that outlives a single screen.
///
/// Assembled once at startup so the rest of the app can assume it exists. If
/// any part of this fails the app is genuinely unusable, so the failure is
/// surfaced on screen rather than swallowed — a worker being handed a phone
/// that silently records nothing is worse than one that says it is broken.
class AppServices {
  AppServices({
    required this.database,
    required this.workers,
    required this.attempts,
    required this.certificates,
    required this.identity,
    required this.codec,
    required this.preferences,
  });

  final AppDatabase database;
  final WorkerRepository workers;
  final AttemptRepository attempts;
  final CertificateRepository certificates;
  final DeviceIdentity identity;
  final CertificateCodec codec;
  final SharedPreferences preferences;

  static const _activeWorkerKey = 'surakshaar.activeWorkerId';

  static Future<AppServices> initialise() async {
    final database = await AppDatabase.open();
    final identity = await DeviceIdentity.loadOrCreate();
    final preferences = await SharedPreferences.getInstance();

    return AppServices(
      database: database,
      workers: WorkerRepository(database),
      attempts: AttemptRepository(database),
      certificates: CertificateRepository(database),
      identity: identity,
      codec: CertificateCodec(),
      preferences: preferences,
    );
  }

  String? get activeWorkerId => preferences.getString(_activeWorkerKey);

  Future<void> setActiveWorker(String? workerId) async {
    if (workerId == null) {
      await preferences.remove(_activeWorkerKey);
    } else {
      await preferences.setString(_activeWorkerKey, workerId);
    }
  }

  Future<WorkerRecord?> activeWorker() async {
    final id = activeWorkerId;
    if (id == null) return null;
    return workers.byId(id);
  }

  /// Every public key this installation can verify against.
  ///
  /// The organisation key is always present because it is compiled in — that is
  /// what lets a fresh install verify a counter-signed certificate with no
  /// network and no prior contact with the issuing site. Device keys are added
  /// as they are learned at sync, and only extend what can be checked; they
  /// never gate the organisation root.
  Future<PublicKeyResolver> keyResolver() async {
    final keys = <String, Uint8List>{
      OrganisationKey.keyId: OrganisationKey.publicKeyBytes,
      identity.keyId: identity.publicKey,
      ...await certificates.knownKeys(),
    };
    return MapKeyResolver(keys);
  }

  Future<void> dispose() => database.close();
}

/// Set once at startup by [servicesProvider]'s bootstrap.
final servicesProvider = Provider<AppServices>((ref) {
  throw StateError(
    'AppServices was read before initialisation. The app must be wrapped in '
    'the ProviderScope override created by bootstrap().',
  );
});

/// The worker currently using the handset.
///
/// Phones are shared on these sites — one handset serves a whole gang — so the
/// active worker is an explicit, switchable choice rather than an assumption
/// baked into the install.
final activeWorkerProvider = FutureProvider<WorkerRecord?>((ref) async {
  final services = ref.watch(servicesProvider);
  return services.activeWorker();
});

final workerListProvider = FutureProvider<List<WorkerRecord>>((ref) async {
  final services = ref.watch(servicesProvider);
  return services.workers.all();
});

final pendingSyncProvider = FutureProvider<int>((ref) async {
  final services = ref.watch(servicesProvider);
  return services.database.pendingSyncCount();
});

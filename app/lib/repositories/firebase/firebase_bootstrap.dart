import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

/// Starting Firebase against the local emulator suite, with no Firebase
/// project behind it.
///
/// ### Why there is no `firebase_options.dart` here
///
/// A project id beginning `demo-` is treated by the emulators as a project that
/// does not exist and never will. Nothing is validated, no credentials are
/// checked, and nothing leaves the machine. That means this build needs no
/// Firebase account, no API key, no `flutterfire configure` step and no
/// `google-services.json`, so anyone marking this work can run the whole thing
/// from a clone.
///
/// The values below are placeholders because they are never used for anything.
/// A real build reads them from a generated `firebase_options.dart`, which is
/// gitignored, and changes nothing else.
///
/// ### Why the emulator rather than a deployment
///
/// Deploying Cloud Functions requires the Blaze plan and a payment method. This
/// project is on the free Spark plan, which emulates functions at no cost but
/// will not deploy them. The code, the signing, the single-use rule and the
/// 120 second life are all real either way. What is untested is the deployment
/// itself, and that is reported as a limitation.
class FirebaseBackend {
  const FirebaseBackend._({
    required this.auth,
    required this.firestore,
    required this.functions,
  });

  final FirebaseAuth auth;
  final FirebaseFirestore firestore;
  final FirebaseFunctions functions;

  /// The region the functions declare. The client has to agree, or the call
  /// goes to a URL that nothing is listening on and fails as a network error,
  /// which is a confusing way to find out about a one word mismatch.
  static const String region = 'australia-southeast1';

  static const String projectId = 'demo-scls';

  /// Where the emulator suite is listening, as seen *from the app*.
  ///
  /// The Android emulator runs its own virtual network, so `localhost` inside
  /// it is the emulated phone and not the development machine. `10.0.2.2` is
  /// the alias Android provides for the host. Overridable for a desktop or web
  /// build, where `localhost` is correct.
  static const String host = String.fromEnvironment(
    'EMULATOR_HOST',
    defaultValue: '10.0.2.2',
  );

  /// Starts Firebase, or picks up the one that is already running.
  ///
  /// Every step here has to tolerate being run twice in one process. A hot
  /// restart re-runs `main()` while the native side survives, so the second
  /// run finds an initialised Firebase app, an Auth instance that is already
  /// pointed at the emulator, and a Firestore instance that has been used and
  /// therefore refuses to be reconfigured.
  ///
  /// The first version of this method assumed a cold start. It threw
  /// `[core/duplicate-app]` on the first hot restart, before `runApp`, so the
  /// screen never rendered and the app looked like it had hung. None of the
  /// 425 automated tests could have found it: they never start Firebase, which
  /// is the point of the repository seam, and hot restart is not a thing a
  /// test does.
  static Future<FirebaseBackend> start() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'demo-key-not-used-by-the-emulator',
          appId: '1:000000000000:android:0000000000000000',
          messagingSenderId: '000000000000',
          projectId: projectId,
        ),
      );
    }

    final auth = FirebaseAuth.instance;
    final firestore = FirebaseFirestore.instance;
    final functions = FirebaseFunctions.instanceFor(region: region);

    await auth.useAuthEmulator(host, 9099);
    functions.useFunctionsEmulator(host, 5001);
    _pointFirestoreAtEmulator(firestore);

    return FirebaseBackend._(
      auth: auth,
      firestore: firestore,
      functions: functions,
    );
  }

  /// Firestore refuses to be reconfigured once it has read or written
  /// anything, which is the state it is in after a hot restart. It is already
  /// pointed at the emulator by then, so the refusal is not a problem.
  static void _pointFirestoreAtEmulator(FirebaseFirestore firestore) {
    try {
      firestore.useFirestoreEmulator(host, 8080);
    } on FirebaseException {
      return;
    } on StateError {
      return;
    }
  }
}

/// Two decorators that put accounts and bookings on the server, without
/// rewriting the repositories that already hold them.
///
/// ### Why a decorator and not a replacement
///
/// The two Cloud Functions need two things that only exist server-side: a
/// Firebase Authentication uid for the caller, and a `reservations` document
/// for the booking. Neither existed, because the prototype kept accounts and
/// bookings in memory. Replacing both repositories outright would have been the
/// tidier design, and with seven days left it would also have put a working
/// demonstration at risk for the sake of tidiness.
///
/// So each repository is wrapped rather than replaced. The wrapper forwards
/// every call to the in-memory implementation, which stays the source of truth
/// for the screens, and then mirrors the result onto the server so the
/// functions have something to read. The classes being wrapped did not change,
/// and neither did any of the 338 tests that cover them.
///
/// This is the Decorator pattern, and it is doing what the pattern is for:
/// adding a responsibility to an object without changing the object or anything
/// that depends on it. It is possible here only because every caller depends on
/// [AuthRepository] and [BookingRepository] rather than on the concrete
/// classes, which is the same property that made the repositories testable.
///
/// ### What it costs
///
/// Two copies of the same data, which can drift. The mirror is written after
/// the in-memory write succeeds and is not transactional with it, so a failed
/// mirror write leaves a booking the app can see and the server cannot. That is
/// a real weakness and it is reported as one rather than hidden. It is
/// acceptable here because the in-memory side is authoritative and the mirror
/// is only ever read by the functions.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;

import '../../models/app_user.dart';
import '../../models/reservation.dart';
import '../auth_repository.dart';
import '../booking_repository.dart';

/// Account identity, mirrored into Firebase Authentication.
///
/// The app and Firebase disagree about what a user id is. The in-memory
/// repository generates its own, and Firebase issues a uid at sign-up. The
/// functions compare against the Firebase uid, so the two have to be matched
/// up. A `users` document keyed by the app's own id holds the mapping, which
/// also lets one account look up another account's uid when handing a booking
/// over.
class MirroredAuthRepository implements AuthRepository {
  MirroredAuthRepository(
    this._inner, {
    required this.auth,
    required this.firestore,
  });

  final AuthRepository _inner;
  final fb.FirebaseAuth auth;
  final FirebaseFirestore firestore;

  final Map<String, String> _uidCache = {};

  @override
  AppUser? get currentUser => _inner.currentUser;

  @override
  Stream<AppUser?> authStateChanges() => _inner.authStateChanges();

  /// The Firebase uid of the signed-in account, or null.
  ///
  /// The callable functions read this from the request themselves. It is
  /// exposed because the booking mirror needs it to stamp an owner onto a
  /// reservation document.
  String? get currentUid => auth.currentUser?.uid;

  @override
  Future<AppUser> register({
    required String email,
    required String password,
    required String displayName,
    String? membershipCode,
  }) async {
    // The in-memory repository goes first and stays the authority. If it
    // refuses, because the membership code is unknown or the password is too
    // short, no Firebase account is created and there is nothing to undo.
    final user = await _inner.register(
      email: email,
      password: password,
      displayName: displayName,
      membershipCode: membershipCode,
    );

    await _mirrorAccount(user, email: email, password: password);
    return user;
  }

  @override
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    final user = await _inner.signIn(email: email, password: password);
    await _mirrorAccount(user, email: email, password: password);
    return user;
  }

  /// Makes sure a Firebase account exists for this app account, and signs in
  /// as it.
  ///
  /// Sign-in is attempted before sign-up because the common case is an account
  /// that already exists. A failure here is swallowed on purpose: the app is
  /// usable without the server, and losing the whole registration because a
  /// local emulator was not running would be a poor trade. What is lost is the
  /// ability to open a locker, which the access screen reports when it happens.
  Future<void> _mirrorAccount(
    AppUser user, {
    required String email,
    required String password,
  }) async {
    try {
      try {
        await auth.signInWithEmailAndPassword(email: email, password: password);
      } on fb.FirebaseAuthException {
        await auth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      }

      final uid = auth.currentUser?.uid;
      if (uid == null) return;

      _uidCache[user.id] = uid;
      await firestore.collection('users').doc(user.id).set({
        'uid': uid,
        'email': email.toLowerCase(),
        'displayName': user.displayName,
      });
    } catch (_) {
      // Deliberately silent. See the comment above this method.
      return;
    }
  }

  /// The Firebase uid behind one of the app's user ids.
  ///
  /// Needed when handing a booking to a neighbour: the token has to record the
  /// uid the neighbour will present, and the neighbour is not the one signed
  /// in at the time.
  Future<String?> uidFor(String appUserId) async {
    final cached = _uidCache[appUserId];
    if (cached != null) return cached;

    try {
      final snapshot = await firestore.collection('users').doc(appUserId).get();
      final uid = snapshot.data()?['uid'] as String?;
      if (uid != null) _uidCache[appUserId] = uid;
      return uid;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    await _inner.signOut();
    try {
      await auth.signOut();
    } catch (_) {
      // Signing out locally is what the user asked for and it has happened.
      return;
    }
  }

  @override
  Future<AppUser> verifyMembership(String membershipCode) =>
      _inner.verifyMembership(membershipCode);

  @override
  Future<AppUser?> findMember(String email) => _inner.findMember(email);
}

/// Bookings, mirrored into Firestore so `issueAccessToken` can read them.
///
/// The function refuses to issue a code unless it can find a reservation that
/// belongs to the caller and is in a state that allows one. That check is the
/// entire point of FR4, so the document has to carry the owner and the state
/// and keep them current.
class MirroredBookingRepository implements BookingRepository {
  MirroredBookingRepository(
    this._inner, {
    required this.firestore,
    required this.currentUid,
  });

  final BookingRepository _inner;
  final FirebaseFirestore firestore;
  final String? Function() currentUid;

  @override
  Future<Reservation> book({
    required String userId,
    required String stationId,
    required String compartmentId,
    required ReservationPurpose purpose,
    required DateTime end,
  }) async {
    // The race is resolved in the in-memory repository, where the check and the
    // hold happen with no await between them. The mirror runs only after a
    // winner exists, so it cannot create one.
    final reservation = await _inner.book(
      userId: userId,
      stationId: stationId,
      compartmentId: compartmentId,
      purpose: purpose,
      end: end,
    );

    await _mirror(reservation);
    return reservation;
  }

  @override
  Future<Reservation> cancel(String reservationId) async {
    final reservation = await _inner.cancel(reservationId);
    await _mirror(reservation);
    return reservation;
  }

  @override
  Future<Reservation> extend(String reservationId, DateTime newEnd) async {
    final reservation = await _inner.extend(reservationId, newEnd);
    await _mirror(reservation);
    return reservation;
  }

  /// Writes the booking where the functions can see it.
  ///
  /// Only the fields the server actually reads are written. A mirror that
  /// copied everything would be a second database, and the two would disagree
  /// the first time one of them changed.
  Future<void> _mirror(Reservation reservation) async {
    final uid = currentUid();
    if (uid == null) return;

    try {
      await firestore.collection('reservations').doc(reservation.id).set({
        'userId': uid,
        'stationId': reservation.stationId,
        'compartmentId': reservation.compartmentId,
        'state': reservation.state.name,
      });
    } catch (_) {
      // The booking exists and the user has been told so. What is lost is the
      // ability to get a code for it, which the access screen reports.
      return;
    }
  }

  @override
  Future<List<Reservation>> fetchBookings(String userId) =>
      _inner.fetchBookings(userId);

  @override
  Future<Reservation?> fetchBooking(String reservationId) =>
      _inner.fetchBooking(reservationId);
}

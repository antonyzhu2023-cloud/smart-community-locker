import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../models/access_token.dart';
import '../../models/door_event.dart';
import '../access_token_repository.dart';
import '../locker_command_gateway.dart';
import 'simulated_cabinet.dart';

/// The real access path: the app asks a Cloud Function, and the function
/// decides.
///
/// This is the implementation Milestone 1 described and Milestone 2 originally
/// shipped as a stand-in. Nothing above this class changed when it replaced
/// [InMemoryAccessBackend]: the screens, the ViewModels and the 338 tests are
/// untouched, because both classes implement the same two interfaces. That was
/// the claim made for the repository layer in Milestone 1, and until this file
/// existed it had never been tested against anything real.
///
/// ### What moved and what did not
///
/// Deciding whether a credential opens a door is now done by
/// `functions/src/index.ts`, running in the Firebase Local Emulator Suite. The
/// signing key is held there as a secret and never reaches the phone, so the
/// app genuinely cannot mint or validate a token even if it wanted to. That is
/// evaluation criterion E4, and it is only meaningful when the decision is out
/// of the client's reach.
///
/// Actuating the door is still simulated, by [SimulatedCabinet], because there
/// is no physical cabinet. The two are separate objects here for the same
/// reason they are separate machines in the design.
///
/// ### Why some calls go straight to Firestore
///
/// Listing the tokens on a booking and withdrawing a hand-over are not
/// decisions about access, so they do not need a function. Milestone 2 cut the
/// backend to two functions and sent everything else straight to Firestore
/// under security rules, which is recorded as a design variation. The rule that
/// survives the cut is the one that matters: only the server may say yes.
class FunctionsAccessBackend
    implements AccessTokenRepository, LockerCommandGateway {
  FunctionsAccessBackend({
    required this.functions,
    required this.firestore,
    required this.cabinet,
    required this.resolveUid,
  });

  final FirebaseFunctions functions;
  final FirebaseFirestore firestore;
  final SimulatedCabinet cabinet;

  /// Turns one of the app's user ids into the Firebase uid that account signs
  /// in with.
  ///
  /// The two are different, and the functions only ever see the Firebase one.
  /// A hand-over has to record the uid the neighbour will present, not the id
  /// the app happens to know them by.
  final Future<String?> Function(String appUserId) resolveUid;

  final _connection = StreamController<bool>.broadcast();
  bool _connected = true;

  // -------------------------------------------------------------------
  // FR4: asking for a credential
  // -------------------------------------------------------------------

  @override
  Future<AccessToken> issue({
    required String reservationId,
    required String userId,
  }) => _issue(reservationId: reservationId);

  @override
  Future<AccessToken> issueDelegated({
    required String reservationId,
    required String userId,
    required String delegateUserId,
  }) async {
    final delegateUid = await resolveUid(delegateUserId);
    if (delegateUid == null) {
      // The neighbour has an app account but has never reached the server, so
      // there is no uid for them to present. Reported as not eligible, which is
      // what it amounts to: they cannot open this locker.
      throw const TokenException(
        TokenFailure.delegateNotEligible,
        'That neighbour cannot be given access yet. Ask them to sign in once.',
      );
    }
    return _issue(reservationId: reservationId, delegateUserId: delegateUid);
  }

  Future<AccessToken> _issue({
    required String reservationId,
    String? delegateUserId,
  }) async {
    final request = <String, dynamic>{'reservationId': reservationId};
    if (delegateUserId != null) {
      request['delegateUserId'] = delegateUserId;
    }

    try {
      final result = await functions
          .httpsCallable('issueAccessToken')
          .call<Map<String, dynamic>>(request);

      final data = result.data;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        (data['expiresAt'] as num).toInt(),
        isUtc: true,
      );

      return AccessToken(
        id: data['tokenId'] as String,
        reservationId: reservationId,
        signedPayload: data['payload'] as String,
        issuedAt: expiresAt.subtract(AccessToken.timeToLive),
        expiresAt: expiresAt,
        delegatedTo: delegateUserId,
        fallbackPin: data['fallbackPin'] as String?,
      );
    } on FirebaseFunctionsException catch (error) {
      throw TokenException(_tokenFailure(error.code), _tokenMessage(error));
    } catch (_) {
      throw const TokenException(
        TokenFailure.network,
        'Could not reach the locker service. Check your connection.',
      );
    }
  }

  /// Maps the function's error code onto the app's own failure list.
  ///
  /// The server deliberately returns `not-found` both for a booking that does
  /// not exist and for one that belongs to somebody else, so that the screen
  /// cannot be used to find out whether a given booking id is real. The mapping
  /// here keeps that conflation rather than trying to undo it.
  TokenFailure _tokenFailure(String code) => switch (code) {
    'unauthenticated' => TokenFailure.notEligible,
    'not-found' => TokenFailure.notFound,
    'failed-precondition' => TokenFailure.bookingNotOpenable,
    'invalid-argument' => TokenFailure.delegateIsOwner,
    'unavailable' || 'deadline-exceeded' => TokenFailure.network,
    _ => TokenFailure.unknown,
  };

  String _tokenMessage(FirebaseFunctionsException error) {
    final message = error.message;
    if (message != null && message.isNotEmpty) return message;
    return 'That code could not be issued.';
  }

  // -------------------------------------------------------------------
  // FR7: withdrawing a hand-over, and listing what is outstanding
  // -------------------------------------------------------------------

  @override
  Future<void> revoke(String tokenId) async {
    final ref = firestore.collection('accessTokens').doc(tokenId);
    final snapshot = await ref.get();

    if (!snapshot.exists) {
      throw const TokenException(
        TokenFailure.tokenGone,
        'That access has already been taken back.',
      );
    }

    // FR7 says a hand-over is revocable *before use*. Revoking a spent token
    // is harmless, because a used code opens nothing, but the message is not:
    // the owner would read "that access has been taken back" and believe the
    // locker had never been opened. It had.
    if (snapshot.data()?['used'] == true) {
      throw const TokenException(
        TokenFailure.tokenGone,
        'That code has already been used, so there is nothing to take back.',
      );
    }

    await ref.delete();
  }

  @override
  Future<List<AccessToken>> tokensFor(String reservationId) async {
    final query = await firestore
        .collection('accessTokens')
        .where('reservationId', isEqualTo: reservationId)
        .get();
    return query.docs.map(_tokenFromDoc).toList();
  }

  @override
  Future<List<AccessToken>> delegationsTo(String userId) async {
    final uid = await resolveUid(userId);
    if (uid == null) return const [];

    // Grants, not codes. A neighbour's list is the hand-overs they hold, and a
    // code they minted under one is theirs to use, not something to show back
    // to them as a second entry.
    final query = await firestore
        .collection('accessTokens')
        .where('delegatedTo', isEqualTo: uid)
        .where('isGrant', isEqualTo: true)
        .where('used', isEqualTo: false)
        .get();
    return query.docs.map(_tokenFromDoc).toList();
  }

  AccessToken _tokenFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    return AccessToken(
      id: doc.id,
      reservationId: data['reservationId'] as String? ?? '',
      // The signed blob is never read back out of Firestore. A payload that can
      // be fetched by anyone who can read the collection is not a credential.
      signedPayload: '',
      issuedAt: _millis(data['issuedAt']),
      expiresAt: _millis(data['expiresAt']),
      singleUse: data['singleUse'] != false,
      used: data['used'] == true,
      delegatedTo: data['delegatedTo'] as String?,
      isGrant: data['isGrant'] == true,
      grantId: data['grantId'] as String?,
    );
  }

  DateTime _millis(Object? value) => DateTime.fromMillisecondsSinceEpoch(
    value is num ? value.toInt() : 0,
    isUtc: true,
  );

  // -------------------------------------------------------------------
  // FR5: presenting a credential
  // -------------------------------------------------------------------

  @override
  Future<OpenOutcome> present({
    required String stationId,
    required String compartmentId,
    String? payload,
    String? pin,
  }) async {
    if (payload == null && pin == null) {
      throw const GatewayException('Nothing was presented.');
    }

    // QR4. The PIN exists so the locker still opens when the network is down,
    // which is exactly when this function cannot be reached. A real cabinet
    // checks it against a hash it cached while it was still online. There is no
    // cabinet here, so the offline path stays with the simulated one and is
    // reported as such.
    if (payload == null) {
      throw const GatewayException(
        'The backup PIN is checked by the cabinet, not by this service.',
      );
    }

    try {
      final result = await functions
          .httpsCallable('handleScan')
          .call<Map<String, dynamic>>({
            'payload': payload,
            'stationId': stationId,
            'compartmentId': compartmentId,
          });

      final data = result.data;
      final accepted = data['accepted'] == true;
      final decision = _decision(data['decision'] as String?);
      final tokenId = data['tokenId'] as String?;
      final now = DateTime.now().toUtc();

      // The server has said yes. Now, and only now, the cabinet is told to
      // move. What the door actually did arrives later on [doorEvents], which
      // is why nothing here claims the compartment is open.
      if (accepted) {
        cabinet.open(
          stationId: stationId,
          compartmentId: compartmentId,
          tokenId: tokenId,
        );
      }

      return OpenOutcome(
        decision: decision,
        message: data['message'] as String? ?? '',
        tokenId: tokenId,
        at: now,
      );
    } on FirebaseFunctionsException catch (error) {
      throw GatewayException(
        error.message ?? 'The locker service refused the request.',
      );
    } catch (_) {
      _setConnected(false);
      throw const GatewayException('Could not reach the locker service.');
    }
  }

  /// The server's vocabulary, mapped onto the app's.
  ///
  /// `unknownToken` and `invalidSignature` both become
  /// [OpenDecision.invalidSignature] here, because the app shows the same
  /// deliberately vague message for both. Telling a holder which of the two it
  /// was tells them whether the token id they guessed exists.
  OpenDecision _decision(String? raw) => switch (raw) {
    'accepted' => OpenDecision.accepted,
    'expired' => OpenDecision.expired,
    'alreadyUsed' => OpenDecision.alreadyUsed,
    'invalidSignature' || 'unknownToken' => OpenDecision.invalidSignature,
    'bookingNotOpenable' => OpenDecision.bookingNotOpenable,
    'notYours' => OpenDecision.notYours,
    'wrongPin' => OpenDecision.wrongPin,
    _ => OpenDecision.unknown,
  };

  @override
  Stream<DoorEvent> doorEvents({
    required String stationId,
    required String compartmentId,
  }) => cabinet.doorEvents(stationId: stationId, compartmentId: compartmentId);

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> connectionChanges() => _connection.stream;

  void _setConnected(bool connected) {
    if (_connected == connected) return;
    _connected = connected;
    _connection.add(connected);
  }

  @override
  Future<void> dispose() async {
    await _connection.close();
    await cabinet.dispose();
  }
}

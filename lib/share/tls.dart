import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import '../data/db.dart';

const _certKey = 'share_tls_cert';
const _keyKey = 'share_tls_key';

/// This phone's own HTTPS certificate for the LocalSend protocol, like the
/// official app makes on each device. Its SHA-256 is our fingerprint, so
/// other devices can tell it's really us.
class TlsIdentity {
  TlsIdentity(this.certificatePem, this.privateKeyPem)
      : fingerprint = sha256
            .convert(CryptoUtils.getBytesFromPEMString(certificatePem))
            .toString()
            .toUpperCase();

  final String certificatePem;
  final String privateKeyPem;
  final String fingerprint;

  SecurityContext context() => SecurityContext()
    ..useCertificateChainBytes(certificatePem.codeUnits)
    ..usePrivateKeyBytes(privateKeyPem.codeUnits);

  /// Loads the saved certificate, or makes one the first time (in the
  /// background, so the app never waits on it).
  static Future<TlsIdentity> load(AppDb db) async {
    final cert = await db.setting(_certKey);
    final key = await db.setting(_keyKey);
    if (cert != null && key != null) return TlsIdentity(cert, key);
    final (newCert, newKey) = await Isolate.run(_generate);
    await db.setSetting(_certKey, newCert);
    await db.setSetting(_keyKey, newKey);
    return TlsIdentity(newCert, newKey);
  }

  /// A brand-new certificate (not saved), for tests.
  static TlsIdentity generate() {
    final (cert, key) = _generate();
    return TlsIdentity(cert, key);
  }

  /// An elliptic-curve (P-256) key: as strong as RSA-3072 for this, and
  /// made in milliseconds instead of seconds.
  static (String, String) _generate() {
    final pair = CryptoUtils.generateEcKeyPair();
    final private = pair.privateKey as ECPrivateKey;
    final public = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'ShareBro', 'O': 'ShareBro', 'C': 'US'},
      private,
      public,
    );
    final cert = X509Utils.generateSelfSignedCertificate(private, csr, 3650);
    return (cert, CryptoUtils.encodeEcPrivateKeyToPem(private));
  }
}

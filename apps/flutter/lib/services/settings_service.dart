import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_config.dart';

/// Singleton that loads/persists all user-configurable credentials from the
/// device's secure keychain. Falls back to AppConfig compile-time defaults
/// so development works without going through onboarding every time.
class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyGatewayUrl = 'oc_gateway_url';
  static const _keyGatewayToken = 'oc_gateway_token';
  static const _keyDeepgramKey = 'oc_deepgram_key';
  static const _keyElevenLabsKey = 'oc_elevenlabs_key';
  static const _keyVoiceId = 'oc_voice_id';
  static const _keyOnboarded = 'oc_onboarded';

  // ── In-memory cache ──────────────────────────────────────────────────────
  String gatewayUrl = '';
  String gatewayToken = '';
  String deepgramKey = '';
  String elevenLabsKey = '';
  String voiceId = '';
  bool onboarded = false;

  bool get isConfigured =>
      gatewayUrl.isNotEmpty &&
      gatewayToken.isNotEmpty &&
      deepgramKey.isNotEmpty &&
      elevenLabsKey.isNotEmpty;

  // ── Derived values ────────────────────────────────────────────────────────
  String get ttsUrl =>
      'https://api.elevenlabs.io/v1/text-to-speech/$voiceId/stream';

  String get deepgramWsUrl =>
      'wss://api.deepgram.com/v1/listen'
      '?model=nova-2'
      '&encoding=linear16'
      '&sample_rate=16000'
      '&channels=1'
      '&interim_results=true'
      '&endpointing=500'
      '&utterance_end_ms=1500';

  // ── Load ──────────────────────────────────────────────────────────────────
  Future<void> load() async {
    gatewayUrl =
        await _storage.read(key: _keyGatewayUrl) ?? AppConfig.openclawGatewayUrl;
    gatewayToken =
        await _storage.read(key: _keyGatewayToken) ?? AppConfig.openclawGatewayToken;
    deepgramKey =
        await _storage.read(key: _keyDeepgramKey) ?? AppConfig.deepgramApiKey;
    elevenLabsKey =
        await _storage.read(key: _keyElevenLabsKey) ?? AppConfig.elevenLabsApiKey;
    voiceId =
        await _storage.read(key: _keyVoiceId) ?? AppConfig.elevenLabsVoiceId;
    onboarded = (await _storage.read(key: _keyOnboarded)) == 'true';
  }

  // ── Save ──────────────────────────────────────────────────────────────────
  Future<void> save({
    required String gatewayUrl,
    required String gatewayToken,
    required String deepgramKey,
    required String elevenLabsKey,
    required String voiceId,
  }) async {
    this.gatewayUrl = gatewayUrl;
    this.gatewayToken = gatewayToken;
    this.deepgramKey = deepgramKey;
    this.elevenLabsKey = elevenLabsKey;
    this.voiceId = voiceId.isNotEmpty ? voiceId : AppConfig.elevenLabsVoiceId;
    onboarded = true;

    await Future.wait([
      _storage.write(key: _keyGatewayUrl, value: this.gatewayUrl),
      _storage.write(key: _keyGatewayToken, value: this.gatewayToken),
      _storage.write(key: _keyDeepgramKey, value: this.deepgramKey),
      _storage.write(key: _keyElevenLabsKey, value: this.elevenLabsKey),
      _storage.write(key: _keyVoiceId, value: this.voiceId),
      _storage.write(key: _keyOnboarded, value: 'true'),
    ]);
  }
}

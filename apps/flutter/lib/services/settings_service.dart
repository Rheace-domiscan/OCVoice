import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// Singleton that loads/persists all user-configurable credentials.
///
/// On macOS we use SharedPreferences (NSUserDefaults) because the macOS sandbox
/// requires a code-signing entitlement for the keychain which breaks unsigned
/// debug builds. On iOS/Android/Windows we use FlutterSecureStorage.
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

  // ── Storage helpers ───────────────────────────────────────────────────────

  bool get _usePrefStorage => Platform.isMacOS;

  Future<String?> _read(String key) async {
    if (_usePrefStorage) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    }
    return _storage.read(key: key);
  }

  Future<void> _write(String key, String value) async {
    if (_usePrefStorage) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  // ── Load ──────────────────────────────────────────────────────────────────
  Future<void> load() async {
    try {
      gatewayUrl = await _read(_keyGatewayUrl) ?? AppConfig.openclawGatewayUrl;
      gatewayToken =
          await _read(_keyGatewayToken) ?? AppConfig.openclawGatewayToken;
      deepgramKey =
          await _read(_keyDeepgramKey) ?? AppConfig.deepgramApiKey;
      elevenLabsKey =
          await _read(_keyElevenLabsKey) ?? AppConfig.elevenLabsApiKey;
      voiceId = await _read(_keyVoiceId) ?? AppConfig.elevenLabsVoiceId;
      onboarded = (await _read(_keyOnboarded)) == 'true';
    } catch (_) {
      // Fallback to compile-time defaults if storage is unavailable
      gatewayUrl = AppConfig.openclawGatewayUrl;
      gatewayToken = AppConfig.openclawGatewayToken;
      deepgramKey = AppConfig.deepgramApiKey;
      elevenLabsKey = AppConfig.elevenLabsApiKey;
      voiceId = AppConfig.elevenLabsVoiceId;
      onboarded = false;
    }
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

    // Persist to storage (best-effort — in-memory cache is the source of truth
    // for the current session regardless)
    try {
      await Future.wait([
        _write(_keyGatewayUrl, this.gatewayUrl),
        _write(_keyGatewayToken, this.gatewayToken),
        _write(_keyDeepgramKey, this.deepgramKey),
        _write(_keyElevenLabsKey, this.elevenLabsKey),
        _write(_keyVoiceId, this.voiceId),
        _write(_keyOnboarded, 'true'),
      ]);
    } catch (_) {
      // Storage failure is non-fatal; in-memory values are still correct
    }
  }
}

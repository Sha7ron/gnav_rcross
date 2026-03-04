import 'package:flutter/foundation.dart';

enum BlinkState { open, closing, closed, opening }

class BlinkDetector {
  static const double _closeThreshold = 0.5;
  static const double _openThreshold = 0.6;
  static const int _minClosedMs = 20;
  static const int _maxQuickBlinkMs = 500;
  static const int _doubleBlinkWindowMs = 1800;
  static const int _longBlinkMinMs = 600;
  static const int _longBlinkMaxMs = 2000;

  bool _longBlinkFired = false;
  BlinkState _state = BlinkState.open;
  DateTime? _closeStartTime;
  DateTime? _lastBlinkTime;
  DateTime? _firstCloseTime;
  int _blinkCount = 0;

  void Function()? onSingleBlink;
  void Function()? onDoubleBlink;

  double _smoothProb = 1.0;
  double _rawProb = 1.0;
  static const double _probAlpha = 0.65;

  int _totalBlinks = 0;
  int _totalDoubleBlinks = 0;
  int _totalLongBlinks = 0;
  String _lastTrigger = '';

  void update(double? leftEyeOpen, double? rightEyeOpen) {
    double prob;
    if (leftEyeOpen != null && rightEyeOpen != null) {
      prob = (leftEyeOpen + rightEyeOpen) / 2.0;
    } else {
      prob = leftEyeOpen ?? rightEyeOpen ?? 1.0;
    }
    _rawProb = prob;
    _smoothProb += (prob - _smoothProb) * _probAlpha;
    final now = DateTime.now();
    final closeProb = _rawProb < _smoothProb ? _rawProb : _smoothProb;
    final openProb = _rawProb > _smoothProb ? _rawProb : _smoothProb;

    switch (_state) {
      case BlinkState.open:
        if (closeProb < _closeThreshold) {
          _state = BlinkState.closing;
          _closeStartTime = now;
          _longBlinkFired = false;
          if (_blinkCount == 0) _firstCloseTime = now;
          debugPrint('BLINK: Eyes closing (prob=${closeProb.toStringAsFixed(2)})');
        }
        if (_blinkCount == 1 && _firstCloseTime != null) {
          if (now.difference(_firstCloseTime!).inMilliseconds > _doubleBlinkWindowMs) {
            _blinkCount = 0;
            _firstCloseTime = null;
            onSingleBlink?.call();
          }
        }
        break;
      case BlinkState.closing:
        if (openProb > _openThreshold) {
          final elapsed = now.difference(_closeStartTime!).inMilliseconds;
          if (elapsed >= _minClosedMs && elapsed <= _maxQuickBlinkMs) {
            _state = BlinkState.open;
            _closeStartTime = null;
            _onQuickBlink(now);
          } else {
            _state = BlinkState.open;
            _closeStartTime = null;
          }
        } else if (now.difference(_closeStartTime!).inMilliseconds >= _minClosedMs) {
          _state = BlinkState.closed;
        }
        break;
      case BlinkState.closed:
        final elapsed = now.difference(_closeStartTime!).inMilliseconds;
        if (openProb > _openThreshold) {
          if (elapsed <= _maxQuickBlinkMs) {
            _state = BlinkState.open;
            _closeStartTime = null;
            _onQuickBlink(now);
          } else if (_longBlinkFired) {
            _state = BlinkState.open;
            _closeStartTime = null;
            _blinkCount = 0;
            _firstCloseTime = null;
          } else {
            _state = BlinkState.open;
            _closeStartTime = null;
          }
        } else {
          if (!_longBlinkFired && elapsed >= _longBlinkMinMs && elapsed <= _longBlinkMaxMs) {
            _longBlinkFired = true;
            _totalLongBlinks++;
            _lastTrigger = 'LONG BLINK';
            debugPrint('BLINK: LONG BLINK (${elapsed}ms) -> SELECT');
            onDoubleBlink?.call();
          }
          if (elapsed > _longBlinkMaxMs + 500) {
            _state = BlinkState.open;
            _closeStartTime = null;
            _longBlinkFired = false;
          }
        }
        break;
      case BlinkState.opening:
        _state = BlinkState.open;
        break;
    }
  }

  void _onQuickBlink(DateTime now) {
    _totalBlinks++;
    debugPrint('BLINK: Quick blink #$_totalBlinks');
    if (_blinkCount == 0) {
      _blinkCount = 1;
      _lastBlinkTime = now;
    } else if (_blinkCount >= 1) {
      final sinceFirstClose = _firstCloseTime != null
          ? now.difference(_firstCloseTime!).inMilliseconds
          : now.difference(_lastBlinkTime!).inMilliseconds;
      if (sinceFirstClose <= _doubleBlinkWindowMs) {
        _blinkCount = 0;
        _lastBlinkTime = null;
        _firstCloseTime = null;
        _totalDoubleBlinks++;
        _lastTrigger = 'DOUBLE BLINK';
        debugPrint('BLINK: DOUBLE BLINK #$_totalDoubleBlinks (${sinceFirstClose}ms)');
        onDoubleBlink?.call();
      } else {
        onSingleBlink?.call();
        _blinkCount = 1;
        _lastBlinkTime = now;
        _firstCloseTime = _closeStartTime ?? now;
      }
    }
  }

  double get eyeOpenProbability => _smoothProb;
  double get rawProbability => _rawProb;
  String get stateLabel {
    if (_state == BlinkState.closed && _closeStartTime != null) {
      final elapsed = DateTime.now().difference(_closeStartTime!).inMilliseconds;
      if (elapsed >= _longBlinkMinMs && !_longBlinkFired) return 'LONG_HOLD';
    }
    return _state.name.toUpperCase();
  }
  int get totalBlinks => _totalBlinks;
  int get totalDoubleBlinks => _totalDoubleBlinks;
  int get totalLongBlinks => _totalLongBlinks;
  String get lastTrigger => _lastTrigger;

  void reset() {
    _state = BlinkState.open;
    _closeStartTime = null;
    _lastBlinkTime = null;
    _firstCloseTime = null;
    _blinkCount = 0;
    _smoothProb = 1.0;
    _rawProb = 1.0;
    _totalBlinks = 0;
    _totalDoubleBlinks = 0;
    _totalLongBlinks = 0;
    _longBlinkFired = false;
    _lastTrigger = '';
  }
}
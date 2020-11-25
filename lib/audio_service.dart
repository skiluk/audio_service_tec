import 'dart:async';
import 'dart:io' show HttpOverrides;
import 'dart:ui';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:rxdart/rxdart.dart';

// TODO:
// - provide a way to manually connect/disconnect.

/// The different buttons on a headset.
enum MediaButton {
  media,
  next,
  previous,
}

/// The actons associated with playing audio.
enum MediaAction {
  stop,
  pause,
  play,
  rewind,
  skipToPrevious,
  skipToNext,
  fastForward,
  setRating,
  seekTo,
  playPause,
  playFromMediaId,
  playFromSearch,
  skipToQueueItem,
  playFromUri,
  prepare,
  prepareFromMediaId,
  prepareFromSearch,
  prepareFromUri,
  setRepeatMode,
  unused_1,
  unused_2,
  setShuffleMode,
  seekBackward,
  seekForward,
}

/// The different states during audio processing.
enum AudioProcessingState {
  idle,
  loading,
  buffering,
  ready,
  completed,
  error,
}

/// The playback state which includes a [playing] boolean state, a processing
/// state such as [AudioProcessingState.buffering], the playback position and
/// the currently enabled actions to be shown in the Android notification or the
/// iOS control center.
class PlaybackState {
  /// The audio processing state e.g. [BasicPlaybackState.buffering].
  final AudioProcessingState processingState;

  /// Whether audio is either playing, or will play as soon as
  /// [processingState] is [AudioProcessingState.ready]. A true value should
  /// be broadcast whenever it would be appropriate for UIs to display a pause
  /// or stop button.
  ///
  /// Since [playing] and [processingState] can vary independently, it is
  /// possible distinguish a particular audio processing state while audio is
  /// playing vs paused. For example, when buffering occurs during a seek, the
  /// [processingState] can be [AudioProcessingState.buffering], but alongside
  /// that [playing] can be true to indicate that the seek was performed while
  /// playing, or false to indicate that the seek was performed while paused.
  final bool playing;

  /// The list of currently enabled controls which should be shown in the media
  /// notification. Each control represents a clickable button with a
  /// [MediaAction] that must be one of:
  ///
  /// * [MediaAction.stop]
  /// * [MediaAction.pause]
  /// * [MediaAction.play]
  /// * [MediaAction.rewind]
  /// * [MediaAction.skipToPrevious]
  /// * [MediaAction.skipToNext]
  /// * [MediaAction.fastForward]
  /// * [MediaAction.playPause]
  final List<MediaControl> controls;

  /// Up to 3 indices of the [controls] that should appear in Android's compact
  /// media notification view. When the notification is expanded, all [controls]
  /// will be shown.
  final List<int> androidCompactActionIndices;

  /// The set of system actions currently enabled. This is for specifying any
  /// other [MediaAction]s that are not supported by [controls], because they do
  /// not represent clickable buttons. For example:
  ///
  /// * [MediaAction.seekTo] (enable a seek bar)
  /// * [MediaAction.seekForward] (enable press-and-hold fast-forward control)
  /// * [MediaAction.seekBackward] (enable press-and-hold rewind control)
  ///
  /// Note that specifying [MediaAction.seekTo] in [systemActions] will enable
  /// a seek bar in both the Android notification and the iOS control center.
  /// [MediaAction.seekForward] and [MediaAction.seekBackward] have a special
  /// behaviour on iOS in which if you have already enabled the
  /// [MediaAction.skipToNext] and [MediaAction.skipToPrevious] buttons, these
  /// additional actions will allow the user to press and hold the buttons to
  /// activate the continuous seeking behaviour.
  final Set<MediaAction> systemActions;

  /// The playback position at [updateTime].
  ///
  /// For efficiency, the [updatePosition] should NOT be updated continuously in
  /// real time. Instead, it should be updated only when the normal continuity
  /// of time is disrupted, such as during a seek, buffering and seeking. When
  /// broadcasting such a position change, the [updateTime] specifies the time
  /// of that change, allowing clients to project the realtime value of the
  /// position as `position + (DateTime.now() - updateTime)`. As a convenience,
  /// this calculation is provided by the [position] getter.
  final Duration updatePosition;

  /// The buffered position.
  final Duration bufferedPosition;

  /// The current playback speed where 1.0 means normal speed.
  final double speed;

  /// The time at which the playback position was last updated.
  final DateTime updateTime;

  /// The current repeat mode.
  final AudioServiceRepeatMode repeatMode;

  /// The current shuffle mode.
  final AudioServiceShuffleMode shuffleMode;

  PlaybackState({
    this.processingState = AudioProcessingState.idle,
    this.playing = false,
    this.controls = const [],
    this.androidCompactActionIndices,
    this.systemActions = const {},
    this.updatePosition = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.speed = 1.0,
    this.repeatMode = AudioServiceRepeatMode.none,
    this.shuffleMode = AudioServiceShuffleMode.none,
  }) : updateTime = DateTime.now() {
    assert(processingState != null);
    assert(playing != null);
    assert(controls != null);
    assert(androidCompactActionIndices == null ||
        androidCompactActionIndices.length <= 3);
    assert(systemActions != null);
    assert(updatePosition != null);
    assert(bufferedPosition != null);
    assert(speed != null);
    assert(repeatMode != null);
    assert(shuffleMode != null);
  }

  PlaybackState copyWith({
    AudioProcessingState processingState,
    bool playing,
    List<MediaControl> controls,
    List<int> androidCompactActionIndices,
    Set<MediaAction> systemActions,
    Duration updatePosition,
    Duration bufferedPosition,
    double speed,
    AudioServiceRepeatMode repeatMode,
    AudioServiceShuffleMode shuffleMode,
  }) =>
      PlaybackState(
        processingState: processingState ?? this.processingState,
        playing: playing ?? this.playing,
        controls: controls ?? this.controls,
        androidCompactActionIndices:
            androidCompactActionIndices ?? this.androidCompactActionIndices,
        systemActions: systemActions ?? this.systemActions,
        updatePosition: updatePosition ?? this.position,
        bufferedPosition: bufferedPosition ?? this.bufferedPosition,
        speed: speed ?? this.speed,
        repeatMode: repeatMode ?? this.repeatMode,
        shuffleMode: shuffleMode ?? this.shuffleMode,
      );

  /// The current playback position.
  Duration get position {
    if (playing && processingState == AudioProcessingState.ready) {
      return Duration(
          milliseconds: (updatePosition.inMilliseconds +
                  ((DateTime.now().millisecondsSinceEpoch -
                          updateTime.millisecondsSinceEpoch) *
                      (speed ?? 1.0)))
              .toInt());
    } else {
      return updatePosition;
    }
  }
}

enum RatingStyle {
  /// Indicates a rating style is not supported.
  ///
  /// A Rating will never have this type, but can be used by other classes
  /// to indicate they do not support Rating.
  none,

  /// A rating style with a single degree of rating, "heart" vs "no heart".
  ///
  /// Can be used to indicate the content referred to is a favorite (or not).
  heart,

  /// A rating style for "thumb up" vs "thumb down".
  thumbUpDown,

  /// A rating style with 0 to 3 stars.
  range3stars,

  /// A rating style with 0 to 4 stars.
  range4stars,

  /// A rating style with 0 to 5 stars.
  range5stars,

  /// A rating style expressed as a percentage.
  percentage,
}

/// A rating to attach to a MediaItem.
class Rating {
  final RatingStyle _type;
  final dynamic _value;

  const Rating._internal(this._type, this._value);

  /// Create a new heart rating.
  const Rating.newHeartRating(bool hasHeart)
      : this._internal(RatingStyle.heart, hasHeart);

  /// Create a new percentage rating.
  factory Rating.newPercentageRating(double percent) {
    if (percent < 0 || percent > 100) throw ArgumentError();
    return Rating._internal(RatingStyle.percentage, percent);
  }

  /// Create a new star rating.
  factory Rating.newStarRating(RatingStyle starRatingStyle, int starRating) {
    if (starRatingStyle != RatingStyle.range3stars &&
        starRatingStyle != RatingStyle.range4stars &&
        starRatingStyle != RatingStyle.range5stars) {
      throw ArgumentError();
    }
    if (starRating > starRatingStyle.index || starRating < 0)
      throw ArgumentError();
    return Rating._internal(starRatingStyle, starRating);
  }

  /// Create a new thumb rating.
  const Rating.newThumbRating(bool isThumbsUp)
      : this._internal(RatingStyle.thumbUpDown, isThumbsUp);

  /// Create a new unrated rating.
  const Rating.newUnratedRating(RatingStyle ratingStyle)
      : this._internal(ratingStyle, null);

  /// Return the rating style.
  RatingStyle getRatingStyle() => _type;

  /// Returns a percentage rating value greater or equal to 0.0f, or a
  /// negative value if the rating style is not percentage-based, or
  /// if it is unrated.
  double getPercentRating() {
    if (_type != RatingStyle.percentage) return -1;
    if (_value < 0 || _value > 100) return -1;
    return _value ?? -1;
  }

  /// Returns a rating value greater or equal to 0.0f, or a negative
  /// value if the rating style is not star-based, or if it is
  /// unrated.
  int getStarRating() {
    if (_type != RatingStyle.range3stars &&
        _type != RatingStyle.range4stars &&
        _type != RatingStyle.range5stars) return -1;
    return _value ?? -1;
  }

  /// Returns true if the rating is "heart selected" or false if the
  /// rating is "heart unselected", if the rating style is not [heart]
  /// or if it is unrated.
  bool hasHeart() {
    if (_type != RatingStyle.heart) return false;
    return _value ?? false;
  }

  /// Returns true if the rating is "thumb up" or false if the rating
  /// is "thumb down", if the rating style is not [thumbUpDown] or if
  /// it is unrated.
  bool isThumbUp() {
    if (_type != RatingStyle.thumbUpDown) return false;
    return _value ?? false;
  }

  /// Return whether there is a rating value available.
  bool isRated() => _value != null;

  Map<String, dynamic> _toRaw() {
    return <String, dynamic>{
      'type': _type.index,
      'value': _value,
    };
  }

  // Even though this should take a Map<String, dynamic>, that makes an error.
  Rating._fromRaw(Map<dynamic, dynamic> raw)
      : this._internal(RatingStyle.values[raw['type']], raw['value']);
}

/// Metadata about an audio item that can be played, or a folder containing
/// audio items.
class MediaItem {
  /// A unique id.
  final String id;

  /// The album this media item belongs to.
  final String album;

  /// The title of this media item.
  final String title;

  /// The artist of this media item.
  final String artist;

  /// The genre of this media item.
  final String genre;

  /// The duration of this media item.
  final Duration duration;

  /// The artwork for this media item as a uri.
  final String artUri;

  /// Whether this is playable (i.e. not a folder).
  final bool playable;

  /// Override the default title for display purposes.
  final String displayTitle;

  /// Override the default subtitle for display purposes.
  final String displaySubtitle;

  /// Override the default description for display purposes.
  final String displayDescription;

  /// The rating of the MediaItem.
  final Rating rating;

  /// A map of additional metadata for the media item.
  ///
  /// The values must be integers or strings.
  final Map<String, dynamic> extras;

  /// Creates a [MediaItem].
  ///
  /// [id], [album] and [title] must not be null, and [id] must be unique for
  /// each instance.
  const MediaItem({
    @required this.id,
    @required this.album,
    @required this.title,
    this.artist,
    this.genre,
    this.duration,
    this.artUri,
    this.playable = true,
    this.displayTitle,
    this.displaySubtitle,
    this.displayDescription,
    this.rating,
    this.extras,
  });

  /// Creates a [MediaItem] from a map of key/value pairs corresponding to
  /// fields of this class.
  factory MediaItem.fromJson(Map raw) => MediaItem(
        id: raw['id'],
        album: raw['album'],
        title: raw['title'],
        artist: raw['artist'],
        genre: raw['genre'],
        duration: raw['duration'] != null
            ? Duration(milliseconds: raw['duration'])
            : null,
        artUri: raw['artUri'],
        playable: raw['playable'],
        displayTitle: raw['displayTitle'],
        displaySubtitle: raw['displaySubtitle'],
        displayDescription: raw['displayDescription'],
        rating: raw['rating'] != null ? Rating._fromRaw(raw['rating']) : null,
        extras: _raw2extras(raw['extras']),
      );

  /// Creates a copy of this [MediaItem] but with with the given fields
  /// replaced by new values.
  MediaItem copyWith({
    String id,
    String album,
    String title,
    String artist,
    String genre,
    Duration duration,
    String artUri,
    bool playable,
    String displayTitle,
    String displaySubtitle,
    String displayDescription,
    Rating rating,
    Map<String, dynamic> extras,
  }) =>
      MediaItem(
        id: id ?? this.id,
        album: album ?? this.album,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        genre: genre ?? this.genre,
        duration: duration ?? this.duration,
        artUri: artUri ?? this.artUri,
        playable: playable ?? this.playable,
        displayTitle: displayTitle ?? this.displayTitle,
        displaySubtitle: displaySubtitle ?? this.displaySubtitle,
        displayDescription: displayDescription ?? this.displayDescription,
        rating: rating ?? this.rating,
        extras: extras ?? this.extras,
      );

  @override
  int get hashCode => id.hashCode;

  @override
  bool operator ==(dynamic other) => other is MediaItem && other.id == id;

  @override
  String toString() => '${toJson()}';

  /// Converts this [MediaItem] to a map of key/value pairs corresponding to
  /// the fields of this class.
  Map<String, dynamic> toJson() => {
        'id': id,
        'album': album,
        'title': title,
        'artist': artist,
        'genre': genre,
        'duration': duration?.inMilliseconds,
        'artUri': artUri,
        'playable': playable,
        'displayTitle': displayTitle,
        'displaySubtitle': displaySubtitle,
        'displayDescription': displayDescription,
        'rating': rating?._toRaw(),
        'extras': extras,
      };

  static Map<String, dynamic> _raw2extras(Map raw) {
    if (raw == null) return null;
    final extras = <String, dynamic>{};
    for (var key in raw.keys) {
      extras[key as String] = raw[key];
    }
    return extras;
  }
}

/// A button to appear in the Android notification, lock screen, Android smart
/// watch, or Android Auto device. The set of buttons you would like to display
/// at any given moment should be set via [AudioServiceBackground.setState].
///
/// Each [MediaControl] button controls a specified [MediaAction]. Only the
/// following actions can be represented as buttons:
///
/// * [MediaAction.stop]
/// * [MediaAction.pause]
/// * [MediaAction.play]
/// * [MediaAction.rewind]
/// * [MediaAction.skipToPrevious]
/// * [MediaAction.skipToNext]
/// * [MediaAction.fastForward]
/// * [MediaAction.playPause]
///
/// Predefined controls with default Android icons and labels are defined as
/// static fields of this class. If you wish to define your own custom Android
/// controls with your own icon resources, you will need to place the Android
/// resources in `android/app/src/main/res`. Here, you will find a subdirectory
/// for each different resolution:
///
/// ```
/// drawable-hdpi
/// drawable-mdpi
/// drawable-xhdpi
/// drawable-xxhdpi
/// drawable-xxxhdpi
/// ```
///
/// You can use [Android Asset
/// Studio](https://romannurik.github.io/AndroidAssetStudio/) to generate these
/// different subdirectories for any standard material design icon.
class MediaControl {
  /// A default control for [MediaAction.stop].
  static final stop = MediaControl(
    androidIcon: 'drawable/audio_service_stop',
    label: 'Stop',
    action: MediaAction.stop,
  );

  /// A default control for [MediaAction.pause].
  static final pause = MediaControl(
    androidIcon: 'drawable/audio_service_pause',
    label: 'Pause',
    action: MediaAction.pause,
  );

  /// A default control for [MediaAction.play].
  static final play = MediaControl(
    androidIcon: 'drawable/audio_service_play_arrow',
    label: 'Play',
    action: MediaAction.play,
  );

  /// A default control for [MediaAction.rewind].
  static final rewind = MediaControl(
    androidIcon: 'drawable/audio_service_fast_rewind',
    label: 'Rewind',
    action: MediaAction.rewind,
  );

  /// A default control for [MediaAction.skipToNext].
  static final skipToNext = MediaControl(
    androidIcon: 'drawable/audio_service_skip_next',
    label: 'Next',
    action: MediaAction.skipToNext,
  );

  /// A default control for [MediaAction.skipToPrevious].
  static final skipToPrevious = MediaControl(
    androidIcon: 'drawable/audio_service_skip_previous',
    label: 'Previous',
    action: MediaAction.skipToPrevious,
  );

  /// A default control for [MediaAction.fastForward].
  static final fastForward = MediaControl(
    androidIcon: 'drawable/audio_service_fast_forward',
    label: 'Fast Forward',
    action: MediaAction.fastForward,
  );

  /// A reference to an Android icon resource for the control (e.g.
  /// `"drawable/ic_action_pause"`)
  final String androidIcon;

  /// A label for the control
  final String label;

  /// The action to be executed by this control
  final MediaAction action;

  const MediaControl({
    @required this.androidIcon,
    @required this.label,
    @required this.action,
  });
}

const MethodChannel _channel =
    const MethodChannel('ryanheise.com/audioService');

const MethodChannel _backgroundChannel =
    const MethodChannel('ryanheise.com/audioServiceBackground');

const String _CUSTOM_PREFIX = 'custom_';

/// Client API to connect with and communciate with the background audio task.
///
/// You may use this API from your UI to send start/pause/play/stop/etc messages
/// to your background audio task, and to listen to state changes broadcast by
/// your background audio task. You may also use this API from other background
/// isolates (e.g. android_alarm_manager) to communicate with the background
/// audio task.
///
/// A client must [connect] to the service before it will be able to send
/// messages to the background audio task, and must [disconnect] when
/// communication is no longer required. In practice, a UI should maintain a
/// connection exactly while it is visible. It is strongly recommended that you
/// use [AudioServiceWidget] to manage this connection for you automatically.
class AudioService {
  /// The cache to use when loading artwork. Defaults to [DefaultCacheManager].
  static BaseCacheManager cacheManager = DefaultCacheManager();

  /// The root media ID for browsing media provided by the background
  /// task.
  static const String MEDIA_ROOT_ID = "root";

  static final _browseMediaChildrenSubject = BehaviorSubject<List<MediaItem>>();

  /// A stream that broadcasts the children of the current browse
  /// media parent.
  static Stream<List<MediaItem>> get browseMediaChildrenStream =>
      _browseMediaChildrenSubject.stream;

  /// The children of the current browse media parent.
  static List<MediaItem> get browseMediaChildren =>
      _browseMediaChildrenSubject.value;

  static final _notificationSubject = BehaviorSubject<bool>.seeded(false);

  /// A stream that broadcasts the status of the notificationClick event.
  static Stream<bool> get notificationClickEventStream =>
      _notificationSubject.stream;

  /// The status of the notificationClick event.
  static bool get notificationClickEvent => _notificationSubject.value;

  /// If a seek is in progress, this holds the position we are seeking to.
  static Duration _seekPos;

  static BehaviorSubject<Duration> _positionSubject;

  static Future<AudioHandler> init({
    @required AudioHandler builder(),
    AudioServiceConfig config = const AudioServiceConfig(),
  }) async {
    print("### AudioService.init");
    WidgetsFlutterBinding.ensureInitialized();
    final handler = (MethodCall call) async {
      print("### UI received ${call.method}");
      switch (call.method) {
        case 'notificationClicked':
          _notificationSubject.add(call.arguments[0]);
          break;
      }
    };
    if (_testing) {
      MethodChannel('ryanheise.com/audioServiceInverse')
          .setMockMethodCallHandler(handler);
    } else {
      _channel.setMethodCallHandler(handler);
    }
    await _channel.invokeMethod('configure', config.toJson());
    final _impl = await _register(
      builder: builder,
      config: config,
    );
    final client = _ClientAudioHandler(_impl);
    return client;
  }

  static AudioServiceConfig _config;
  static AudioHandler _handler;

  static AudioServiceConfig get config => _config;

  /// Runs the background audio task within the background isolate.
  ///
  /// This must be the first method called by the entrypoint of your background
  /// task that you passed into [AudioService.start]. The [AudioHandler]
  /// returned by the [builder] parameter defines callbacks to handle the
  /// initialization and distruction of the background audio task, as well as
  /// any requests by the client to play, pause and otherwise control audio
  /// playback.
  static Future<AudioHandler> _register({
    @required AudioHandler builder(),
    AudioServiceConfig config = const AudioServiceConfig(),
  }) async {
    assert(_config == null && _handler == null);
    print("### AudioServiceBackground._register");
    _config = config;
    _handler = builder();
    final handler = (MethodCall call) async {
      print('### background received ${call.method}');
      try {
        switch (call.method) {
          case 'onLoadChildren':
            final List args = call.arguments;
            String parentMediaId = args[0];
            final mediaItems = await _onLoadChildren(parentMediaId);
            List<Map> rawMediaItems =
                mediaItems.map((item) => item.toJson()).toList();
            return rawMediaItems as dynamic;
          case 'onClick':
            final List args = call.arguments;
            MediaButton button = MediaButton.values[args[0]];
            await _handler.click(button);
            break;
          case 'onStop':
            await _handler.stop();
            break;
          case 'onPause':
            await _handler.pause();
            break;
          case 'onPrepare':
            await _handler.prepare();
            break;
          case 'onPrepareFromMediaId':
            final List args = call.arguments;
            String mediaId = args[0];
            await _handler.prepareFromMediaId(mediaId);
            break;
          case 'onPlay':
            await _handler.play();
            break;
          case 'onPlayFromMediaId':
            final List args = call.arguments;
            String mediaId = args[0];
            await _handler.playFromMediaId(mediaId);
            break;
          case 'onPlayMediaItem':
            await _handler.playMediaItem(MediaItem.fromJson(call.arguments[0]));
            break;
          case 'onAddQueueItem':
            await _handler.addQueueItem(MediaItem.fromJson(call.arguments[0]));
            break;
          case 'onAddQueueItemAt':
            final List args = call.arguments;
            MediaItem mediaItem = MediaItem.fromJson(args[0]);
            int index = args[1];
            await _handler.insertQueueItem(index, mediaItem);
            break;
          case 'onUpdateQueue':
            final List args = call.arguments;
            final List queue = args[0];
            await _handler.updateQueue(
                queue?.map((raw) => MediaItem.fromJson(raw))?.toList());
            break;
          case 'onUpdateMediaItem':
            await _handler
                .updateMediaItem(MediaItem.fromJson(call.arguments[0]));
            break;
          case 'onRemoveQueueItem':
            await _handler
                .removeQueueItem(MediaItem.fromJson(call.arguments[0]));
            break;
          case 'onSkipToNext':
            await _handler.skipToNext();
            break;
          case 'onSkipToPrevious':
            await _handler.skipToPrevious();
            break;
          case 'onFastForward':
            await _handler.fastForward(_config.fastForwardInterval);
            break;
          case 'onRewind':
            await _handler.rewind(_config.rewindInterval);
            break;
          case 'onSkipToQueueItem':
            final List args = call.arguments;
            String mediaId = args[0];
            await _handler.skipToQueueItem(mediaId);
            break;
          case 'onSeekTo':
            final List args = call.arguments;
            int positionMs = args[0];
            Duration position = Duration(milliseconds: positionMs);
            await _handler.seekTo(position);
            break;
          case 'onSetRepeatMode':
            final List args = call.arguments;
            await _handler
                .setRepeatMode(AudioServiceRepeatMode.values[args[0]]);
            break;
          case 'onSetShuffleMode':
            final List args = call.arguments;
            await _handler
                .setShuffleMode(AudioServiceShuffleMode.values[args[0]]);
            break;
          case 'onSetRating':
            await _handler.setRating(
                Rating._fromRaw(call.arguments[0]), call.arguments[1]);
            break;
          case 'onSeekBackward':
            final List args = call.arguments;
            await _handler.seekBackward(args[0]);
            break;
          case 'onSeekForward':
            final List args = call.arguments;
            await _handler.seekForward(args[0]);
            break;
          case 'onSetSpeed':
            final List args = call.arguments;
            double speed = args[0];
            await _handler.setSpeed(speed);
            break;
          case 'onTaskRemoved':
            await _handler.onTaskRemoved();
            break;
          case 'onClose':
            await _handler.onNotificationDeleted();
            break;
          default:
            if (call.method.startsWith(_CUSTOM_PREFIX)) {
              final result = await _handler.customAction(
                  call.method.substring(_CUSTOM_PREFIX.length), call.arguments);
              return result;
            }
            break;
        }
      } catch (e, stacktrace) {
        print('$stacktrace');
        throw PlatformException(code: '$e');
      }
    };
    // Mock method call handlers only work in one direction so we need to set up
    // a separate channel for each direction when testing.
    if (_testing) {
      MethodChannel('ryanheise.com/audioServiceBackgroundInverse')
          .setMockMethodCallHandler(handler);
    } else {
      _backgroundChannel.setMethodCallHandler(handler);
    }
    _handler.mediaItemStream.listen((mediaItem) async {
      if (mediaItem == null) return;
      if (mediaItem.artUri != null) {
        // We potentially need to fetch the art.
        String filePath = _getLocalPath(mediaItem.artUri);
        if (filePath == null) {
          final fileInfo = cacheManager.getFileFromMemory(mediaItem.artUri);
          filePath = fileInfo?.file?.path;
          if (filePath == null) {
            // We haven't fetched the art yet, so show the metadata now, and again
            // after we load the art.
            await _backgroundChannel.invokeMethod(
                'setMediaItem', mediaItem.toJson());
            // Load the art
            filePath = await _loadArtwork(mediaItem);
            // If we failed to download the art, abort.
            if (filePath == null) return;
          }
        }
        final extras = Map.of(mediaItem.extras ?? <String, dynamic>{});
        extras['artCacheFile'] = filePath;
        final platformMediaItem = mediaItem.copyWith(extras: extras);
        // Show the media item after the art is loaded.
        await _backgroundChannel.invokeMethod(
            'setMediaItem', platformMediaItem.toJson());
      } else {
        await _backgroundChannel.invokeMethod(
            'setMediaItem', mediaItem.toJson());
      }
    });
    _handler.queueStream.listen((queue) async {
      if (queue == null) return;
      if (_config.preloadArtwork) {
        _loadAllArtwork(queue);
      }
      await _backgroundChannel.invokeMethod(
          'setQueue', queue.map((item) => item.toJson()).toList());
    });
    _handler.playbackStateStream.listen((playbackState) async {
      List<Map> rawControls = playbackState.controls
          .map((control) => {
                'androidIcon': control.androidIcon,
                'label': control.label,
                'action': control.action.index,
              })
          .toList();
      final rawSystemActions =
          playbackState.systemActions.map((action) => action.index).toList();
      // TODO: use playbackState.toJson()
      await _backgroundChannel.invokeMethod('setState', [
        rawControls,
        rawSystemActions,
        playbackState.processingState.index,
        playbackState.playing,
        playbackState.updatePosition.inMilliseconds,
        playbackState.bufferedPosition.inMilliseconds,
        playbackState.speed,
        playbackState.updateTime?.millisecondsSinceEpoch,
        playbackState.androidCompactActionIndices,
        playbackState.repeatMode.index,
        playbackState.shuffleMode.index,
      ]);
    });

    return _handler;
  }

  /// Shuts down the background audio task within the background isolate.
  static Future<void> _stop() async {
    final audioSession = await AudioSession.instance;
    try {
      await audioSession.setActive(false);
    } catch (e) {
      print("While deactivating audio session: $e");
    }
    await _backgroundChannel.invokeMethod('stopService');
  }

  static Future<void> _loadAllArtwork(List<MediaItem> queue) async {
    for (var mediaItem in queue) {
      await _loadArtwork(mediaItem);
    }
  }

  static Future<String> _loadArtwork(MediaItem mediaItem) async {
    try {
      final artUri = mediaItem.artUri;
      if (artUri != null) {
        String local = _getLocalPath(artUri);
        if (local != null) {
          return local;
        } else {
          final file = await cacheManager.getSingleFile(mediaItem.artUri);
          return file.path;
        }
      }
    } catch (e) {}
    return null;
  }

  static String _getLocalPath(String artUri) {
    const prefix = "file://";
    if (artUri.toLowerCase().startsWith(prefix)) {
      return artUri.substring(prefix.length);
    }
    return null;
  }

  static final _childrenStreams = <String, ValueStream<List<MediaItem>>>{};
  static Future<List<MediaItem>> _onLoadChildren(String parentMediaId) async {
    var childrenStream = _childrenStreams[parentMediaId];
    if (childrenStream == null) {
      childrenStream = _childrenStreams[parentMediaId] =
          _handler.getChildrenStream(parentMediaId);
      childrenStream.listen((children) {
        // Notify clients that the children of [parentMediaId] have changed.
        _backgroundChannel.invokeMethod('notifyChildrenChanged', parentMediaId);
      });
    }
    return _childrenStreams[parentMediaId].value;
  }

  /// Starts a background audio task which will continue running even when the
  /// UI is not visible or the screen is turned off. Only one background audio task
  /// may be running at a time.
  ///
  /// While the background task is running, it will display a system
  /// notification showing information about the current media item being
  /// played (see [AudioServiceBackground.setMediaItem]) along with any media
  /// controls to perform any media actions that you want to support (see
  /// [AudioServiceBackground.setState]).
  ///
  /// The background task is specified by [backgroundTaskEntrypoint] which will
  /// be run within a background isolate. This function must be a top-level
  /// function, and it must initiate execution by calling
  /// [AudioServiceBackground.run]. Because the background task runs in an
  /// isolate, no memory is shared between the background isolate and your main
  /// UI isolate and so all communication between the background task and your
  /// UI is achieved through message passing.
  ///
  /// The [androidNotificationIcon] is specified like an XML resource reference
  /// and defaults to `"mipmap/ic_launcher"`.
  ///
  /// [androidShowNotificationBadge] enable notification badges (also known as notification dots)
  /// to appear on a launcher icon when the app has an active notification.
  ///
  /// If specified, [androidArtDownscaleSize] causes artwork to be downscaled
  /// to the given resolution in pixels before being displayed in the
  /// notification and lock screen. If not specified, no downscaling will be
  /// performed. If the resolution of your artwork is particularly high,
  /// downscaling can help to conserve memory.
  ///
  /// [params] provides a way to pass custom parameters through to the
  /// `onStart` method of your background audio task. If specified, this must
  /// be a map consisting of keys/values that can be encoded via Flutter's
  /// `StandardMessageCodec`.
  ///
  /// [fastForwardInterval] and [rewindInterval] are passed through to your
  /// background audio task as properties, and they represent the duration
  /// of audio that should be skipped in fast forward / rewind operations. On
  /// iOS, these values also configure the intervals for the skip forward and
  /// skip backward buttons. Note that both [fastForwardInterval] and
  /// [rewindInterval] must be positive durations.
  ///
  /// [androidEnableQueue] enables queue support on the media session on
  /// Android. If your app will run on Android and has a queue, you should set
  /// this to true.
  ///
  /// [androidStopForegroundOnPause] will switch the Android service to a lower
  /// priority state when playback is paused allowing the user to swipe away the
  /// notification. Note that while in this lower priority state, the operating
  /// system will also be able to kill your service at any time to reclaim
  /// resources.
  static Future<bool> configure({
    @required Function backgroundTaskEntrypoint,
    String androidNotificationChannelName = "Notifications",
    String androidNotificationChannelDescription,
    int androidNotificationColor,
    String androidNotificationIcon = 'mipmap/ic_launcher',
    bool androidShowNotificationBadge = false,
    bool androidNotificationClickStartsActivity = true,
    bool androidNotificationOngoing = false,
    bool androidResumeOnClick = true,
    bool androidStopForegroundOnPause = false,
    bool androidEnableQueue = false,
    Size androidArtDownscaleSize,
    //Duration fastForwardInterval = const Duration(seconds: 10),
    //Duration rewindInterval = const Duration(seconds: 10),
  }) async {
    //assert(fastForwardInterval > Duration.zero,
    //    "fastForwardDuration must be positive");
    //assert(rewindInterval > Duration.zero, "rewindInterval must be positive");

    final success = await _channel.invokeMethod('configure', {
      'androidNotificationChannelName': androidNotificationChannelName,
      'androidNotificationChannelDescription':
          androidNotificationChannelDescription,
      'androidNotificationColor': androidNotificationColor,
      'androidNotificationIcon': androidNotificationIcon,
      'androidShowNotificationBadge': androidShowNotificationBadge,
      'androidNotificationClickStartsActivity':
          androidNotificationClickStartsActivity,
      'androidNotificationOngoing': androidNotificationOngoing,
      'androidResumeOnClick': androidResumeOnClick,
      'androidStopForegroundOnPause': androidStopForegroundOnPause,
      'androidEnableQueue': androidEnableQueue,
      'artDownscaleWidth': androidArtDownscaleSize?.width?.round(),
      'artDownscaleHeight': androidArtDownscaleSize?.height?.round(),
    });
    backgroundTaskEntrypoint();
    return success;
  }

  /// Sets the parent of the children that [browseMediaChildrenStream] broadcasts.
  /// If unspecified, the root parent will be used.
  static Future<void> setBrowseMediaParent(
      [String parentMediaId = MEDIA_ROOT_ID]) async {
    await _channel.invokeMethod('setBrowseMediaParent', parentMediaId);
  }

  /// A stream tracking the current position, suitable for animating a seek bar.
  /// To ensure a smooth animation, this stream emits values more frequently on
  /// short media items where the seek bar moves more quickly, and less
  /// frequenly on long media items where the seek bar moves more slowly. The
  /// interval between each update will be no quicker than once every 16ms and
  /// no slower than once every 200ms.
  ///
  /// See [createPositionStream] for more control over the stream parameters.
  //static Stream<Duration> _positionStream;
  static Stream<Duration> getPositionStream(AudioHandler handler) {
    if (_positionSubject == null) {
      _positionSubject = BehaviorSubject<Duration>(sync: true);
      _positionSubject.addStream(createPositionStream(
          handler: handler,
          steps: 800,
          minPeriod: Duration(milliseconds: 16),
          maxPeriod: Duration(milliseconds: 200)));
    }
    return _positionSubject.stream;
  }

  /// Creates a new stream periodically tracking the current position. The
  /// stream will aim to emit [steps] position updates at intervals of
  /// [duration] / [steps]. This interval will be clipped between [minPeriod]
  /// and [maxPeriod]. This stream will not emit values while audio playback is
  /// paused or stalled.
  ///
  /// Note: each time this method is called, a new stream is created. If you
  /// intend to use this stream multiple times, you should hold a reference to
  /// the returned stream.
  static Stream<Duration> createPositionStream({
    @required AudioHandler handler,
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) {
    assert(minPeriod <= maxPeriod);
    assert(minPeriod > Duration.zero);
    Duration last;
    // ignore: close_sinks
    StreamController<Duration> controller;
    StreamSubscription<MediaItem> mediaItemSubscription;
    StreamSubscription<PlaybackState> playbackStateSubscription;
    Timer currentTimer;
    Duration duration() => handler.mediaItem?.duration ?? Duration.zero;
    Duration step() {
      var s = duration() ~/ steps;
      if (s < minPeriod) s = minPeriod;
      if (s > maxPeriod) s = maxPeriod;
      return s;
    }

    void yieldPosition(Timer timer) {
      if (last != (_seekPos ?? handler.playbackState?.position)) {
        controller.add(last = (_seekPos ?? handler.playbackState?.position));
      }
    }

    controller = StreamController.broadcast(
      sync: true,
      onListen: () {
        mediaItemSubscription = handler.mediaItemStream.listen((mediaItem) {
          // Potentially a new duration
          currentTimer?.cancel();
          currentTimer = Timer.periodic(step(), yieldPosition);
        });
        playbackStateSubscription = handler.playbackStateStream.listen((state) {
          // Potentially a time discontinuity
          yieldPosition(currentTimer);
        });
      },
      onCancel: () {
        mediaItemSubscription.cancel();
        playbackStateSubscription.cancel();
      },
    );

    return controller.stream;
  }

  /// In Android, forces media button events to be routed to your active media
  /// session.
  ///
  /// This is necessary if you want to play TextToSpeech in the background and
  /// still respond to media button events. You should call it just before
  /// playing TextToSpeech.
  ///
  /// This is not necessary if you are playing normal audio in the background
  /// such as music because this kind of "normal" audio playback will
  /// automatically qualify your app to receive media button events.
  static Future<void> androidForceEnableMediaButtons() async {
    await _backgroundChannel.invokeMethod('androidForceEnableMediaButtons');
  }
}

// XXX: If one link in the chain calls on another method, how do we make it
// enter at the head of the chain?
// - chain in reverse. The actual implementation should be the inner-most child.
// XXX: We don't want every link in the chain to have behavior subjects.
abstract class AudioHandler {
  AudioHandler._();

  /// Prepare media items for playback.
  Future<void> prepare();

  /// Prepare a specific media item for playback.
  Future<void> prepareFromMediaId(String mediaId);

  /// Start or resume playback.
  Future<void> play();

  /// Play a specific media item.
  Future<void> playFromMediaId(String mediaId);

  /// Play a specific media item.
  Future<void> playMediaItem(MediaItem mediaItem);

  /// Pause playback.
  Future<void> pause();

  /// Process a headset button click, where [button] defaults to
  /// [MediaButton.media].
  Future<void> click([MediaButton button]);

  /// Stop playback and release resources.
  Future<void> stop();

  /// Add [mediaItem] to the queue.
  Future<void> addQueueItem(MediaItem mediaItem);

  /// Add [mediaItems] to the queue.
  Future<void> addQueueItems(List<MediaItem> mediaItems);

  /// Insert [mediaItem] into the queue at position [index].
  Future<void> insertQueueItem(int index, MediaItem mediaItem);

  /// Update to the queue to [queue].
  Future<void> updateQueue(List<MediaItem> queue);

  /// Update the properties of [mediaItem].
  Future<void> updateMediaItem(MediaItem mediaItem);

  /// Remove [mediaItem] from the queue.
  Future<void> removeQueueItem(MediaItem mediaItem);

  /// Skip to the next item in the queue.
  Future<void> skipToNext();

  /// Skip to the previous item in the queue.
  Future<void> skipToPrevious();

  /// Jump forward by [interval], defaulting to
  /// [AudioServiceConfig.fastForwardInterval].
  Future<void> fastForward([Duration interval]);

  /// Jump backward by [interval], defaulting to
  /// [AudioServiceConfig.rewindInterval]. Note: this value must be positive.
  Future<void> rewind([Duration interval]);

  /// Skip to a media item.
  Future<void> skipToQueueItem(String mediaId);

  /// Seek to [position].
  Future<void> seekTo(Duration position);

  /// Set the rating.
  Future<void> setRating(Rating rating, Map<dynamic, dynamic> extras);

  /// Set the repeat mode.
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode);

  /// Set the shuffle mode.
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode);

  /// Begin or end seeking backward continuously.
  Future<void> seekBackward(bool begin);

  /// Begin or end seeking forward continuously.
  Future<void> seekForward(bool begin);

  /// Set the playback speed.
  Future<void> setSpeed(double speed);

  /// A mechanism to support app-specific actions.
  Future<dynamic> customAction(String name, dynamic arguments);

  /// Handle the task being swiped away in the task manager (Android).
  Future<void> onTaskRemoved();

  /// Handle the notification being swiped away (Android).
  Future<void> onNotificationDeleted();

  /// Get the children of a parent media item.
  Future<List<MediaItem>> getChildren(String parentMediaId);

  /// Get a value stream of the children of a parent media item.
  ValueStream<List<MediaItem>> getChildrenStream(String parentMediaId);

  /// A value stream of playback states.
  ValueStream<PlaybackState> get playbackStateStream;

  /// The current playback state.
  PlaybackState get playbackState => playbackStateStream.value;

  /// A value stream of the current queue.
  ValueStream<List<MediaItem>> get queueStream;

  /// The current queue.
  List<MediaItem> get queue => queueStream.value;

  /// A value stream of the current media item.
  ValueStream<MediaItem> get mediaItemStream;

  /// The current media item.
  MediaItem get mediaItem => mediaItemStream.value;

  /// A stream of custom events.
  Stream<dynamic> get customEventStream;
}

class _ClientAudioHandler extends CompositeAudioHandler {
  _ClientAudioHandler(AudioHandler impl) : super(impl);

  @override
  Future<void> click([MediaButton button]) async {
    await super.click(button ?? MediaButton.media);
  }

  @override
  Future<void> fastForward([Duration interval]) async {
    await super
        .fastForward(interval ?? AudioService.config.fastForwardInterval);
  }

  @override
  Future<void> rewind([Duration interval]) async {
    await super.rewind(interval ?? AudioService.config.rewindInterval);
  }
}

class CompositeAudioHandler extends AudioHandler {
  AudioHandler _inner;

  CompositeAudioHandler(AudioHandler inner)
      : _inner = inner,
        super._() {
    assert(inner != null);
  }

  @mustCallSuper
  Future<void> prepare() => _inner.prepare();

  @mustCallSuper
  Future<void> prepareFromMediaId(String mediaId) =>
      _inner.prepareFromMediaId(mediaId);

  @mustCallSuper
  Future<void> play() => _inner.play();

  @mustCallSuper
  Future<void> playFromMediaId(String mediaId) =>
      _inner.playFromMediaId(mediaId);

  @mustCallSuper
  Future<void> playMediaItem(MediaItem mediaItem) =>
      _inner.playMediaItem(mediaItem);

  @mustCallSuper
  Future<void> pause() => _inner.pause();

  @mustCallSuper
  Future<void> click([MediaButton button]) => _inner.click(button);

  @mustCallSuper
  Future<void> stop() => _inner.stop();

  @mustCallSuper
  Future<void> addQueueItem(MediaItem mediaItem) =>
      _inner.addQueueItem(mediaItem);

  @mustCallSuper
  Future<void> addQueueItems(List<MediaItem> mediaItems) =>
      _inner.addQueueItems(mediaItems);

  @mustCallSuper
  Future<void> insertQueueItem(int index, MediaItem mediaItem) =>
      _inner.insertQueueItem(index, mediaItem);

  @mustCallSuper
  Future<void> updateQueue(List<MediaItem> queue) => _inner.updateQueue(queue);

  @mustCallSuper
  Future<void> updateMediaItem(MediaItem mediaItem) =>
      _inner.updateMediaItem(mediaItem);

  @mustCallSuper
  Future<void> removeQueueItem(MediaItem mediaItem) =>
      _inner.removeQueueItem(mediaItem);

  @mustCallSuper
  Future<void> skipToNext() => _inner.skipToNext();

  @mustCallSuper
  Future<void> skipToPrevious() => _inner.skipToPrevious();

  @mustCallSuper
  Future<void> fastForward([Duration interval]) => _inner.fastForward(interval);

  @mustCallSuper
  Future<void> rewind([Duration interval]) => _inner.rewind();

  @mustCallSuper
  Future<void> skipToQueueItem(String mediaId) =>
      _inner.skipToQueueItem(mediaId);

  @mustCallSuper
  Future<void> seekTo(Duration position) => _inner.seekTo(position);

  @mustCallSuper
  Future<void> setRating(Rating rating, Map<dynamic, dynamic> extras) =>
      _inner.setRating(rating, extras);

  @mustCallSuper
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _inner.setRepeatMode(repeatMode);

  @mustCallSuper
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _inner.setShuffleMode(shuffleMode);

  @mustCallSuper
  Future<void> seekBackward(bool begin) => _inner.seekBackward(begin);

  @mustCallSuper
  Future<void> seekForward(bool begin) => _inner.seekForward(begin);

  @mustCallSuper
  Future<void> setSpeed(double speed) => _inner.setSpeed(speed);

  @mustCallSuper
  Future<dynamic> customAction(String name, dynamic arguments) =>
      _inner.customAction(name, arguments);

  @mustCallSuper
  Future<void> onTaskRemoved() => _inner.onTaskRemoved();

  @mustCallSuper
  Future<void> onNotificationDeleted() => _inner.onNotificationDeleted();

  @mustCallSuper
  Future<List<MediaItem>> getChildren(String parentMediaId) =>
      _inner.getChildren(parentMediaId);

  @mustCallSuper
  ValueStream<List<MediaItem>> getChildrenStream(String parentMediaId) =>
      _inner.getChildrenStream(parentMediaId);

  @mustCallSuper
  ValueStream<PlaybackState> get playbackStateStream =>
      _inner.playbackStateStream;

  @mustCallSuper
  PlaybackState get playbackState => _inner.playbackState;

  @mustCallSuper
  ValueStream<List<MediaItem>> get queueStream => _inner.queueStream;

  @mustCallSuper
  List<MediaItem> get queue => _inner.queue;

  @mustCallSuper
  ValueStream<MediaItem> get mediaItemStream => _inner.mediaItemStream;

  @mustCallSuper
  MediaItem get mediaItem => _inner.mediaItem;

  @override
  Stream<dynamic> get customEventStream => _inner.customEventStream;
}

abstract class BaseAudioHandler extends AudioHandler {
  /// A controller for broadcasting the current [PlaybackState] to the app's UI,
  /// media notification and other clients. Example usage:
  ///
  /// ```dart
  /// playbackStateSubject.add(playbackState.copyWith(playing: true));
  /// ```
  @protected
  // ignore: close_sinks
  final playbackStateSubject = BehaviorSubject.seeded(PlaybackState());

  /// A controller for broadcasting the current queue to the app's UI, media
  /// notification and other clients. Example usage:
  ///
  /// ```dart
  /// queueSubject.add(queue + [additionalItem]);
  /// ```
  @protected
  // ignore: close_sinks
  final queueSubject = BehaviorSubject.seeded(<MediaItem>[]);

  /// A controller for broadcasting the current media item to the app's UI,
  /// media notification and other clients. Example usage:
  ///
  /// ```dart
  /// mediaItemSubject.add(item);
  /// ```
  @protected
  // ignore: close_sinks, unnecessary_cast
  final mediaItemSubject = BehaviorSubject.seeded(null as MediaItem);

  /// A controller for broadcasting a custom event to the app's UI. Example
  /// usage:
  ///
  /// ```dart
  /// customEventSubject.add(MyCustomEvent(arg: 3));
  /// ```
  @protected
  // ignore: close_sinks
  final customEventSubject = PublishSubject<dynamic>();

  BaseAudioHandler() : super._();

  @override
  Future<void> prepare() async {}

  @override
  Future<void> prepareFromMediaId(String mediaId) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> playFromMediaId(String mediaId) async {}

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> click([MediaButton button]) async {
    switch (button) {
      case MediaButton.media:
        if (playbackState?.playing == true) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  @override
  @mustCallSuper
  Future<void> stop() async {
    await AudioService._stop();
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {}

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {}

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {}

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {}

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {}

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> fastForward([Duration interval]) async {}

  @override
  Future<void> rewind([Duration interval]) async {}

  @override
  Future<void> skipToQueueItem(String mediaId) async {}

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Future<void> setRating(Rating rating, Map<dynamic, dynamic> extras) async {}

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {}

  @override
  Future<void> seekBackward(bool begin) async {}

  @override
  Future<void> seekForward(bool begin) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<dynamic> customAction(String name, dynamic arguments) async {}

  @override
  Future<void> onTaskRemoved() async {}

  @override
  Future<void> onNotificationDeleted() async {
    await stop();
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId) async => null;

  @override
  ValueStream<List<MediaItem>> getChildrenStream(String parentMediaId) => null;

  @override
  ValueStream<PlaybackState> get playbackStateStream =>
      playbackStateSubject.stream;

  @override
  ValueStream<List<MediaItem>> get queueStream => queueSubject.stream;

  @override
  ValueStream<MediaItem> get mediaItemStream => mediaItemSubject.stream;

  @override
  Stream<dynamic> get customEventStream => customEventSubject.stream;
}

mixin SeekHandler on BaseAudioHandler {
  _Seeker _seeker;

  @override
  Future<void> fastForward([Duration interval]) => _seekRelative(interval);

  @override
  Future<void> rewind([Duration interval]) => _seekRelative(-interval);

  @override
  Future<void> seekForward(bool begin) async => _seekContinuously(begin, 1);

  @override
  Future<void> seekBackward(bool begin) async => _seekContinuously(begin, -1);

  /// Jumps away from the current position by [offset].
  Future<void> _seekRelative(Duration offset) async {
    var newPosition = playbackState.position + offset;
    // Make sure we don't jump out of bounds.
    if (newPosition < Duration.zero) newPosition = Duration.zero;
    if (newPosition > mediaItem.duration) newPosition = mediaItem.duration;
    // Perform the jump via a seek.
    await seekTo(newPosition);
  }

  /// Begins or stops a continuous seek in [direction]. After it begins it will
  /// continue seeking forward or backward by 10 seconds within the audio, at
  /// intervals of 1 second in app time.
  void _seekContinuously(bool begin, int direction) {
    _seeker?.stop();
    if (begin) {
      _seeker = _Seeker(this, Duration(seconds: 10 * direction),
          Duration(seconds: 1), mediaItem)
        ..start();
    }
  }
}

class _Seeker {
  final AudioHandler handler;
  final Duration positionInterval;
  final Duration stepInterval;
  final MediaItem mediaItem;
  bool _running = false;

  _Seeker(
    this.handler,
    this.positionInterval,
    this.stepInterval,
    this.mediaItem,
  );

  start() async {
    _running = true;
    while (_running) {
      Duration newPosition = handler.playbackState.position + positionInterval;
      if (newPosition < Duration.zero) newPosition = Duration.zero;
      if (newPosition > mediaItem.duration) newPosition = mediaItem.duration;
      handler.seekTo(newPosition);
      await Future.delayed(stepInterval);
    }
  }

  stop() {
    _running = false;
  }
}

mixin QueueHandler on BaseAudioHandler {
  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    queueSubject.add(queue..add(mediaItem));
    return super.addQueueItem(mediaItem);
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    queueSubject.add(queue..addAll(mediaItems));
    return super.addQueueItems(mediaItems);
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    queueSubject.add(queue..insert(index, mediaItem));
    return super.insertQueueItem(index, mediaItem);
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    queueSubject.add(this.queue..replaceRange(0, this.queue.length, queue));
    return super.updateQueue(queue);
  }

  @override
  Future<void> updateMediaItem(MediaItem mediaItem) async {
    queueSubject.add(this.queue..[this.queue.indexOf(mediaItem)] = mediaItem);
    return super.updateMediaItem(mediaItem);
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    queueSubject.add(this.queue..remove(mediaItem));
    return super.removeQueueItem(mediaItem);
  }

  @override
  Future<void> skipToNext() async {
    await _skip(1);
    return super.skipToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    await _skip(-1);
    return super.skipToPrevious();
  }

  Future<void> skipToQueueItem(String mediaId) async {
    final mediaItem = queue.firstWhere((mediaItem) => mediaItem.id == mediaId);
    mediaItemSubject.add(mediaItem);
  }

  Future<void> _skip(int offset) async {
    if (mediaItem == null) return;
    int i = queue.indexOf(mediaItem);
    if (i == -1) return;
    int newIndex = i + offset;
    if (newIndex >= 0 && newIndex < queue.length) {
      await skipToQueueItem(queue[newIndex]?.id);
    }
  }
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler {
  @override
  // TODO: implement playbackStateStream
  ValueStream<PlaybackState> get playbackStateStream =>
      throw UnimplementedError();

  @override
  // TODO: implement mediaItemStream
  ValueStream<MediaItem> get mediaItemStream => throw UnimplementedError();
}

enum AudioServiceShuffleMode { none, all, group }

enum AudioServiceRepeatMode { none, one, all, group }

bool get _testing => HttpOverrides.current != null;

class AudioServiceConfig {
  final bool androidResumeOnClick;
  final String androidNotificationChannelName;
  final String androidNotificationChannelDescription;
  final int notificationColor;
  final String androidNotificationIcon;
  final bool androidShowNotificationBadge;
  final bool androidNotificationClickStartsActivity;
  final bool androidNotificationOngoing;
  final bool androidStopForegroundOnPause;
  final int artDownscaleWidth;
  final int artDownscaleHeight;
  final Duration fastForwardInterval;
  final Duration rewindInterval;
  final bool androidEnableQueue;
  final bool preloadArtwork;

  const AudioServiceConfig({
    this.androidResumeOnClick = true,
    this.androidNotificationChannelName = "Notifications",
    this.androidNotificationChannelDescription,
    this.notificationColor,
    this.androidNotificationIcon = 'mipmap/ic_launcher',
    this.androidShowNotificationBadge = false,
    this.androidNotificationClickStartsActivity = true,
    this.androidNotificationOngoing = false,
    this.androidStopForegroundOnPause = false,
    this.artDownscaleWidth,
    this.artDownscaleHeight,
    this.fastForwardInterval = const Duration(seconds: 10),
    this.rewindInterval = const Duration(seconds: 10),
    this.androidEnableQueue = false,
    this.preloadArtwork = false,
  });

  Map<String, dynamic> toJson() => {
        'androidResumeOnClick': androidResumeOnClick,
        'androidNotificationChannelName': androidNotificationChannelName,
        'androidNotificationChannelDescription':
            androidNotificationChannelDescription,
        'notificationColor': notificationColor,
        'androidNotificationIcon': androidNotificationIcon,
        'androidShowNotificationBadge': androidShowNotificationBadge,
        'androidNotificationClickStartsActivity':
            androidNotificationClickStartsActivity,
        'androidNotificationOngoing': androidNotificationOngoing,
        'androidStopForegroundOnPause': androidStopForegroundOnPause,
        'artDownscaleWidth': artDownscaleWidth,
        'artDownscaleHeight': artDownscaleHeight,
        'fastForwardInterval': fastForwardInterval.inMilliseconds,
        'rewindInterval': rewindInterval.inMilliseconds,
        'androidEnableQueue': androidEnableQueue,
        'preloadArtwork': preloadArtwork,
      };
}

/**
 * @providesModule MusicControl
 */
"use strict";

import {
  NativeModules,
  DeviceEventEmitter,
  NativeEventEmitter,
  Platform
} from "react-native";
const NativeMusicControl = NativeModules.MusicControlManager;
import resolveAssetSource from "react-native/Libraries/Image/resolveAssetSource";
import constants from "./constants";

let handlers = {};
let listenerOfNativeMusicControl = null;
const IS_ANDROID = Platform.OS === "android";

const MusicControl = {
  STATE_PLAYING: constants.STATE_PLAYING,
  STATE_PAUSED: constants.STATE_PAUSED,
  STATE_ERROR: constants.STATE_ERROR,
  STATE_STOPPED: constants.STATE_STOPPED,
  STATE_BUFFERING: constants.STATE_BUFFERING,

  RATING_HEART: constants.RATING_HEART,
  RATING_THUMBS_UP_DOWN: constants.RATING_THUMBS_UP_DOWN,
  RATING_3_STARS: constants.RATING_3_STARS,
  RATING_4_STARS: constants.RATING_4_STARS,
  RATING_5_STARS: constants.RATING_5_STARS,
  RATING_PERCENTAGE: constants.RATING_PERCENTAGE,

  enableBackgroundMode: function(enable) {
    NativeMusicControl.enableBackgroundMode(enable);
  },
  updatePlaying: function(state, details, controls=[]) {
    // Check if we have an android asset from react style image require
    if (details.artwork) {
      details.artwork = resolveAssetSource(details.artwork) || details.artwork;
    }

    NativeMusicControl.updatePlaying(state, details, controls);
  },
  reset: function() {
    NativeMusicControl.reset();
  },
  enableControl: function(controlName, enable, options = {}) {
    NativeMusicControl.enableControl(controlName, enable, options || {});
  },
  handleCommand: function(commandName, value) {
    if (handlers[commandName]) {
      handlers[commandName](value);
    }
  },
  on: function(actionName, cb) {
    if (!listenerOfNativeMusicControl) {
      listenerOfNativeMusicControl = (IS_ANDROID
        ? DeviceEventEmitter
        : new NativeEventEmitter(NativeMusicControl)
      ).addListener("RNMusicControlEvent", event => {
        MusicControl.handleCommand(event.name, event.value);
      });
    }
    handlers[actionName] = cb;
  },
  off: function(actionName, cb) {
    delete handlers[actionName];
    if (!Object.keys(handlers).length && listenerOfNativeMusicControl) {
      listenerOfNativeMusicControl.remove();
      listenerOfNativeMusicControl = null;
    }
  },
  stopControl: function() {
    if (listenerOfNativeMusicControl) {
      listenerOfNativeMusicControl.remove();
      listenerOfNativeMusicControl = null;
    }
    handlers = {};
    NativeMusicControl.stopControl();
  },
  handleAudioInterruptions: function(enable) {
    if (IS_ANDROID) {
      console.log("Audio interruption handling not implemented for Android");
    } else {
      NativeMusicControl.observeAudioInterruptions(enable);
    }
  }
};

export default MusicControl;

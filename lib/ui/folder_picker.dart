import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'android_file_browser.dart';

/// 폴더 고르기. Android 는 앱 안 화면 (내장 저장소 · SD 카드 · USB 를 실제 경로로 고를 수 있음), PC 는 Windows 폴더 선택 창
Future<String?> pickFolder(BuildContext context, String title, [String? initial]) => Platform.isAndroid
    ? showAndroidFolderBrowser(context, title: title, initialDirectory: initial)
    : FilePicker.getDirectoryPath(dialogTitle: title, initialDirectory: initial);

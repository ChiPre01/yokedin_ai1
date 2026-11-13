import 'package:yoked_in/calls/recording_file_store_base.dart';
import 'package:yoked_in/calls/recording_file_store_io.dart'
    if (dart.library.html) 'package:yoked_in/calls/recording_file_store_web.dart'
    as impl;

export 'package:yoked_in/calls/recording_file_store_base.dart';

RecordingFileStore createRecordingFileStore() => impl.createRecordingFileStore();

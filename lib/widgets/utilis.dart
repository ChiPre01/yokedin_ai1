import 'package:cherry_toast/cherry_toast.dart';
import 'package:cherry_toast/resources/arrays.dart';
import 'package:flutter/material.dart';

enum SnackbarType { success, error }

void showAppSnackbar({
  required BuildContext context,
  required SnackbarType type,
  required String description,
}) {
  switch (type) {
    case SnackbarType.success:
      CherryToast.success(
        toastDuration: Duration(milliseconds: 2500),
        height: 70,
        toastPosition: Position.top,
        shadowColor: Colors.white,

        animationType: AnimationType.fromTop,
        displayCloseButton: false,
        backgroundColor: Colors.green.withAlpha(40),
        description: Text(
          description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.green),
        ),
        title: const Text(
          "Successful",
          style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
        ),
      ).show(context);
      break;

    case SnackbarType.error:
      CherryToast.error(
        toastDuration: Duration(milliseconds: 2500),
        // Firebase error strings are long; a fixed 70 px toast with a
        // wrapping message overflowed. Two ellipsised lines fit the taller box.
        height: 88,
        toastPosition: Position.top,
        shadowColor: Colors.white,
        animationType: AnimationType.fromTop,
        displayCloseButton: false,
        backgroundColor: Colors.red.withAlpha(40),
        description: Text(
          description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.red),
        ),
        title: const Text(
          "Fail",
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
        ),
      ).show(context);
      break;
  }
}


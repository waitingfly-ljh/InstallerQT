// Self-test entry: loads the same UI component set on the minimal platform to verify the QML module and runtime dependencies are available.
// The main program loads this component instead of Main during --selftest (Main's root is a Window, which can also
// be created on the minimal platform, but here we deliberately do only "compile + instantiate" without entering the window display flow).
import QtQuick
import SetupUi

AppFrame {
}

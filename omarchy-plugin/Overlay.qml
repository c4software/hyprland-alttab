import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "logic.js" as Logic

PanelWindow {
    id: panel

    required property var service

    // Hover only selects once the pointer really moved after the
    // overlay opened — the surface maps under a stationary cursor,
    // which must not steal the selection (GTK-version semantics).
    property bool hoverArmed: false
    property point initialPos: Qt.point(-1, -1)

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "omarchy-alttab"
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight

    // Always focus the selection; only Escape cancels. Cancelling
    // when the pointer had left the overlay meant any cursor movement
    // (or a focus warp) silently dropped the chosen window.
    function activate() {
        service.close(true);
    }

    // Fast-tap race: modifier released before the exclusive keyboard
    // grant delivers any event. While no event has been seen, ask the
    // compositor for the real modifier state (the GDK query of the
    // Rust version); once an event arrives the key handlers own the
    // closing decision.
    Timer {
        id: noKeyTimer
        interval: 150
        repeat: true
        running: true
        onTriggered: {
            if (service.sawKeyEvent) {
                if (service.heldEmpty() && !service.modsHeld) panel.activate();
                else stop();
            } else {
                modCheck.running = true;
            }
        }
    }

    Process {
        id: modCheck
        command: ["hyprctl", "eval",
            'error(tostring(hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R") or hl.is_key_down("Super_L") or hl.is_key_down("Super_R")))']
        stdout: StdioCollector {
            onStreamFinished: {
                if (!service.open || service.sawKeyEvent) return;
                if (!text.trim().endsWith("true"))
                    panel.activate();
            }
        }
    }

    Rectangle {
        id: content
        anchors.fill: parent
        color: Color.background
        border.color: Color.accent
        border.width: 2
        radius: 16
        implicitWidth: column.implicitWidth + 40
        implicitHeight: column.implicitHeight + 40

        focus: true

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onPositionChanged: (mouse) => {
                if (panel.hoverArmed) return;
                if (panel.initialPos.x < 0) {
                    panel.initialPos = Qt.point(mouse.x, mouse.y);
                    return;
                }
                if (Math.abs(mouse.x - panel.initialPos.x) + Math.abs(mouse.y - panel.initialPos.y) > 3)
                    panel.hoverArmed = true;
            }
        }

        Keys.onPressed: (event) => {
            service.sawKeyEvent = true;
            service.modsHeld = !!(event.modifiers & (Qt.AltModifier | Qt.MetaModifier));
            if (event.key === Qt.Key_Escape) {
                service.close(false);
                event.accepted = true;
                return;
            }
            if (!service.isModifierKey(event.key))
                service.heldKeys[event.key] = true;
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Right) {
                service.next();
                event.accepted = true;
            } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Left) {
                service.prev();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                panel.activate();
                event.accepted = true;
            } else if (event.key === Qt.Key_P && !event.isAutoRepeat) {
                service.togglePreviews();
                event.accepted = true;
            } else if (event.key === Qt.Key_F && !event.isAutoRepeat) {
                service.toggleHighlight();
                event.accepted = true;
            } else if (event.key === Qt.Key_Q && !event.isAutoRepeat) {
                service.closeSelected();
                event.accepted = true;
            }
        }

        Keys.onReleased: (event) => {
            service.sawKeyEvent = true;
            delete service.heldKeys[event.key];
            // event.modifiers may still include the modifier being
            // released — subtract it explicitly, like the Rust port.
            const altReleasing = event.key === Qt.Key_Alt;
            const superReleasing = event.key === Qt.Key_Meta
                || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R;
            const altHeld = (event.modifiers & Qt.AltModifier) && !altReleasing;
            const superHeld = (event.modifiers & Qt.MetaModifier) && !superReleasing;
            service.modsHeld = !!(altHeld || superHeld);
            if (!service.modsHeld && (altReleasing || superReleasing || service.heldEmpty()))
                panel.activate();
        }

        Column {
            id: column
            anchors.centerIn: parent
            spacing: 0

            // One long row of groups: with enough windows it is wider
            // than the screen, and the selection could sit past either
            // edge with nothing to show it. Cap it at the screen and
            // scroll the selected frame into view.
            Flickable {
                id: strip
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(groupsRow.implicitWidth, panel.screen ? panel.screen.width - 120 : 1600)
                height: groupsRow.implicitHeight
                contentWidth: groupsRow.implicitWidth
                contentHeight: height
                clip: true
                interactive: contentWidth > width
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalFlick

                // Leave a frame's worth of margin, so the neighbour in
                // the scroll direction hints that there is more.
                function reveal(x, w) {
                    if (contentWidth <= width)
                        return;
                    const margin = 48;
                    if (x - margin < contentX)
                        contentX = Math.max(0, x - margin);
                    else if (x + w + margin > contentX + width)
                        contentX = Math.min(contentWidth - width, x + w + margin - width);
                }

                Behavior on contentX {
                    NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                }

            Row {
                id: groupsRow
                spacing: 0

                Repeater {
                    model: service.groups

                    Row {
                        required property var modelData
                        required property int index
                        spacing: 0

                        Rectangle {
                            visible: index > 0
                            width: 1
                            height: wsCol.height
                            color: Qt.alpha(Color.foreground, 0.2)
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            id: wsCol
                            spacing: 4
                            leftPadding: index > 0 ? 16 : 8
                            rightPadding: 8

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: Logic.shortWorkspaceName(modelData.name)
                                textFormat: Text.PlainText
                                color: Qt.alpha(Color.foreground, 0.5)
                                font.pixelSize: 11
                                bottomPadding: 4
                                // A name that is neither numbered nor
                                // slotted can still be long; keep the end,
                                // which is what tells two apart.
                                width: Math.min(implicitWidth, 240)
                                elide: Text.ElideLeft
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 8

                                Repeater {
                                    model: modelData.entries

                                    Rectangle {
                                        id: frame
                                        required property var modelData
                                        property bool isSelected: service.selected === modelData.flatIdx
                                        onIsSelectedChanged: if (isSelected) strip.reveal(frame.mapToItem(groupsRow, 0, 0).x, frame.width)
                                        readonly property var source: service.toplevelByAddr[modelData.addr.replace(/^0x/, "")] || null

                                        width: thumb.width + 24
                                        height: service.previews ? thumb.height + caption.height + 26 : thumb.height + 20
                                        radius: 12
                                        color: isSelected
                                            ? Qt.alpha(Color.accent, frameHover.hovered ? 0.4 : 0.25)
                                            : "transparent"
                                        opacity: modelData.hidden ? 0.75 : 1.0
                                        border.width: modelData.hidden ? 1 : 0
                                        border.color: Qt.alpha(Color.accent, 0.45)

                                        // Still frame of the window; the app icon stands in
                                        // until it arrives or when capture is unavailable.
                                        Rectangle {
                                            id: thumb
                                            x: 12
                                            y: service.previews ? 12 : 10
                                            width: service.previews ? Logic.tileWidth(frame.modelData, service.thumbHeight) : service.thumbHeight
                                            height: service.thumbHeight
                                            radius: 6
                                            color: service.previews ? Qt.alpha(Color.foreground, 0.06) : "transparent"
                                            clip: true

                                            ScreencopyView {
                                                id: capture
                                                anchors.fill: parent
                                                captureSource: service.open && service.previews ? frame.source : null
                                                live: false
                                                paintCursor: false
                                                constraintSize: Qt.size(Math.max(1, width), Math.max(1, height))
                                                visible: hasContent
                                            }

                                            Image {
                                                id: icon
                                                readonly property int size: capture.hasContent
                                                    ? Math.round(Math.min(32, service.thumbHeight * 0.3))
                                                    : service.previews ? Math.round(Math.min(64, service.thumbHeight * 0.55)) : 64
                                                // Centered placeholder, then a corner badge over the preview.
                                                x: capture.hasContent ? parent.width - size - 6 : (parent.width - size) / 2
                                                y: capture.hasContent ? parent.height - size - 6 : (parent.height - size) / 2
                                                width: size
                                                height: size
                                                sourceSize.width: 64
                                                sourceSize.height: 64
                                                source: service.icons.iconPathFor(frame.modelData.cls, frame.modelData.title, frame.modelData.pid)
                                                visible: source != "" && status !== Image.Error
                                            }

                                            Rectangle {
                                                x: icon.x
                                                y: icon.y
                                                width: icon.size
                                                height: icon.size
                                                radius: icon.size / 4
                                                visible: !icon.visible
                                                color: Qt.alpha(Color.accent, 0.3)

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: (frame.modelData.cls || "?").charAt(0).toUpperCase()
                                                    textFormat: Text.PlainText
                                                    color: Color.foreground
                                                    font.pixelSize: Math.round(icon.size / 2)
                                                    font.bold: true
                                                }
                                            }
                                        }

                                        Rectangle {
                                            visible: service.hasBadge(frame.modelData.addr)
                                            x: thumb.x + thumb.width - width / 2 - 2
                                            y: thumb.y - height / 2 + 2
                                            width: 14
                                            height: 14
                                            radius: 7
                                            color: "#e5484d"
                                            border.width: 2
                                            border.color: Color.background
                                        }

                                        Text {
                                            id: caption
                                            anchors.top: thumb.bottom
                                            anchors.topMargin: 6
                                            anchors.horizontalCenter: thumb.horizontalCenter
                                            width: thumb.width
                                            visible: service.previews
                                            text: frame.modelData.title
                                            textFormat: Text.PlainText
                                            color: frame.isSelected ? Color.foreground : Qt.alpha(Color.foreground, 0.65)
                                            font.pixelSize: 11
                                            elide: Text.ElideRight
                                            horizontalAlignment: Text.AlignHCenter
                                            maximumLineCount: 1
                                        }

                                        property bool hoverSelect: frameHover.hovered && panel.hoverArmed
                                        onHoverSelectChanged: if (hoverSelect) service.selected = frame.modelData.flatIdx

                                        HoverHandler {
                                            id: frameHover
                                        }

                                        TapHandler {
                                            onTapped: {
                                                service.selected = frame.modelData.flatIdx;
                                                panel.activate();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            }

            // Fixed width/height so changing titles never resize the overlay.
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                topPadding: 10
                width: Math.min(strip.width, 600)
                height: topPadding + 22
                maximumLineCount: 1
                text: service.flat.length
                    ? service.flat[service.selected].cls + "  —  " + service.flat[service.selected].title
                    : ""
                textFormat: Text.PlainText
                color: Color.foreground
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}

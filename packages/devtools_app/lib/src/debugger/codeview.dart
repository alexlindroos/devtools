// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:vm_service/vm_service.dart' hide Stack;

import '../auto_dispose_mixin.dart';
import '../common_widgets.dart';
import '../config_specific/logger/logger.dart';
import '../flutter_widgets/linked_scroll_controller.dart';
import '../theme.dart';
import '../ui/utils.dart';
import '../utils.dart';
import 'breakpoints.dart';
import 'common.dart';
import 'debugger_controller.dart';
import 'debugger_model.dart';
import 'hover.dart';
import 'syntax_highlighter.dart';
import 'variables.dart';

// TODO(kenz): consider moving lines / pausedPositions calculations to the
// controller.
class CodeView extends StatefulWidget {
  const CodeView({
    Key key,
    this.controller,
    this.scriptRef,
    this.onSelected,
  }) : super(key: key);

  static const rowHeight = 20.0;
  static const assumedCharacterWidth = 16.0;

  final DebuggerController controller;
  final ScriptRef scriptRef;

  final void Function(ScriptRef scriptRef, int line) onSelected;

  @override
  _CodeViewState createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> with AutoDisposeMixin {
  Script script;
  int lineCount = 0;
  Set<int> executableLines = {};

  LinkedScrollControllerGroup verticalController;
  ScrollController gutterController;
  ScrollController textController;
  SyntaxHighlighter highlighter;

  ScriptRef get scriptRef => widget.scriptRef;

  @override
  void initState() {
    super.initState();

    _initScriptInfo();
    verticalController = LinkedScrollControllerGroup();
    gutterController = verticalController.addAndGet();
    textController = verticalController.addAndGet();

    addAutoDisposeListener(
        widget.controller.scriptLocation, _handleScriptLocationChanged);
  }

  void _parseScriptLines() {
    // Create a new SyntaxHighlighter with the script's source in preparation
    // for building the code view.
    highlighter = SyntaxHighlighter(source: script?.source ?? '');
    lineCount = script.source?.split('\n')?.length ?? 0;

    // Gather the data to display breakable lines.
    executableLines = {};

    if (script != null) {
      final scriptId = script.id;

      widget.controller
          .getBreakablePositions(script)
          .then((List<SourcePosition> positions) {
        if (mounted && scriptId == scriptRef?.id) {
          setState(() {
            executableLines = Set.from(positions.map((p) => p.line));
          });
        }
      }).catchError((e, st) {
        // Ignore - not supported for all vm service implementations.
        log('$e\n$st');
      });
    }
  }

  @override
  void didUpdateWidget(CodeView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.controller != oldWidget.controller) {
      cancel();

      addAutoDisposeListener(
          widget.controller.scriptLocation, _handleScriptLocationChanged);
    }

    if (widget.scriptRef != oldWidget.scriptRef) {
      _initScriptInfo();
    }
  }

  @override
  void dispose() {
    gutterController.dispose();
    textController.dispose();
    widget.controller.scriptLocation
        .removeListener(_handleScriptLocationChanged);
    super.dispose();
  }

  void _initScriptInfo() {
    script = widget.controller.getScriptCached(scriptRef);

    if (script == null) {
      if (scriptRef != null) {
        final scriptId = scriptRef.id;
        widget.controller.getScript(scriptRef).then((script) {
          if (mounted && scriptId == scriptRef.id) {
            setState(() {
              this.script = script;

              _parseScriptLines();
            });
          }
        });
      }
    } else {
      _parseScriptLines();
    }
  }

  void _handleScriptLocationChanged() {
    if (mounted) {
      _updateScrollPosition();
    }
  }

  void _updateScrollPosition({bool animate = true}) {
    if (widget.controller.scriptLocation.value.scriptRef != scriptRef) {
      return;
    }

    final location = widget.controller.scriptLocation.value?.location;
    if (location?.line == null) {
      return;
    }

    if (!verticalController.hasAttachedControllers) {
      // TODO(devoncarew): I'm uncertain why this occurs.
      log('LinkedScrollControllerGroup has no attached controllers');
      return;
    }

    final position = verticalController.position;
    final extent = position.extentInside;

    // TODO(devoncarew): Adjust this so we don't scroll if we're already in the
    // middle third of the screen.
    if (lineCount * CodeView.rowHeight > extent) {
      // Scroll to the middle of the screen.
      final lineIndex = location.line - 1;
      final scrollPosition =
          lineIndex * CodeView.rowHeight - (extent - CodeView.rowHeight) / 2;
      if (animate) {
        verticalController.animateTo(
          scrollPosition,
          duration: longDuration,
          curve: defaultCurve,
        );
      } else {
        verticalController.jumpTo(scrollPosition);
      }
    }
  }

  void _onPressed(int line) {
    widget.onSelected(scriptRef, line);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (scriptRef == null) {
      return Center(
        child: Text(
          'No script selected',
          style: theme.textTheme.subtitle1,
        ),
      );
    }

    if (script == null) {
      return const CenteredCircularProgressIndicator();
    }

    return buildCodeArea(context);
  }

  Widget buildCodeArea(BuildContext context) {
    final theme = Theme.of(context);

    final lines = <TextSpan>[];

    // Ensure the syntax highlighter has been initialized.
    // TODO(bkonyi): process source for highlighting on a separate thread.
    if (script.source.length < 500000 && highlighter != null) {
      final highlighted = highlighter.highlight(context);

      // Look for [TextSpan]s which only contain '\n' to manually break the
      // output from the syntax highlighter into individual lines.
      var currentLine = <TextSpan>[];
      highlighted.visitChildren((span) {
        currentLine.add(span);
        if (span.toPlainText() == '\n') {
          lines.add(
            TextSpan(
              style: theme.fixedFontStyle,
              children: currentLine,
            ),
          );
          currentLine = <TextSpan>[];
        }
        return true;
      });
      lines.add(
        TextSpan(
          style: theme.fixedFontStyle,
          children: currentLine,
        ),
      );
    } else {
      lines.addAll(
        [
          for (final line in script.source.split('\n'))
            TextSpan(
              style: theme.fixedFontStyle,
              text: line,
            ),
        ],
      );
    }

    // Apply the log change-of-base formula, then add 16dp padding for every
    // digit in the maximum number of lines.
    final gutterWidth = CodeView.assumedCharacterWidth * 1.5 +
        CodeView.assumedCharacterWidth *
            (defaultEpsilon + math.log(math.max(lines.length, 100)) / math.ln10)
                .truncateToDouble();

    _updateScrollPosition(animate: false);

    return OutlineDecoration(
      child: Column(
        children: [
          buildCodeviewTitle(theme),
          DefaultTextStyle(
            style: theme.fixedFontStyle,
            child: Expanded(
              child: Scrollbar(
                child: ValueListenableBuilder<StackFrameAndSourcePosition>(
                  valueListenable: widget.controller.selectedStackFrame,
                  builder: (context, frame, _) {
                    final pausedFrame = frame == null
                        ? null
                        : (frame.scriptRef == scriptRef ? frame : null);

                    return Row(
                      children: [
                        ValueListenableBuilder<
                            List<BreakpointAndSourcePosition>>(
                          valueListenable:
                              widget.controller.breakpointsWithLocation,
                          builder: (context, breakpoints, _) {
                            return Gutter(
                              gutterWidth: gutterWidth,
                              scrollController: gutterController,
                              lineCount: lines.length,
                              pausedFrame: pausedFrame,
                              breakpoints: breakpoints
                                  .where((bp) => bp.scriptRef == scriptRef)
                                  .toList(),
                              executableLines: executableLines,
                              onPressed: _onPressed,
                            );
                          },
                        ),
                        const SizedBox(width: denseSpacing),
                        Expanded(
                          child: Lines(
                            scrollController: textController,
                            lines: lines,
                            pausedFrame: pausedFrame,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildCodeviewTitle(ThemeData theme) {
    return ValueListenableBuilder(
      valueListenable: widget.controller.scriptsHistory,
      builder: (context, scriptsHistory, _) {
        return debuggerSectionTitle(
          theme,
          child: Row(
            children: [
              ToolbarAction(
                icon: Icons.chevron_left,
                onPressed:
                    scriptsHistory.hasPrevious ? scriptsHistory.moveBack : null,
              ),
              ToolbarAction(
                icon: Icons.chevron_right,
                onPressed:
                    scriptsHistory.hasNext ? scriptsHistory.moveForward : null,
              ),
              const SizedBox(width: denseSpacing),
              const VerticalDivider(thickness: 1.0),
              const SizedBox(width: defaultSpacing),
              Expanded(
                child: Text(
                  scriptRef?.uri ?? ' ',
                  style: theme.textTheme.subtitle2,
                ),
              ),
              const SizedBox(width: denseSpacing),
              PopupMenuButton<ScriptRef>(
                itemBuilder: _buildScriptMenuFromHistory,
                enabled: scriptsHistory.hasScripts,
                onSelected: (scriptRef) {
                  widget.controller
                      .showScriptLocation(ScriptLocation(scriptRef));
                },
                offset: const Offset(
                  actionsIconSize + denseSpacing,
                  buttonMinWidth + denseSpacing,
                ),
                child: const Icon(
                  Icons.keyboard_arrow_down,
                  size: actionsIconSize,
                ),
              ),
              const SizedBox(width: denseSpacing),
            ],
          ),
        );
      },
    );
  }

  List<PopupMenuEntry<ScriptRef>> _buildScriptMenuFromHistory(
    BuildContext context,
  ) {
    const scriptHistorySize = 16;

    return widget.controller.scriptsHistory.openedScripts
        .take(scriptHistorySize)
        .map((scriptRef) {
      return PopupMenuItem(
        value: scriptRef,
        child: Text(
          scriptRef.uri,
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
          style: const TextStyle(fontSize: 14.0),
        ),
      );
    }).toList();
  }
}

typedef IntCallback = void Function(int value);

class Gutter extends StatelessWidget {
  const Gutter({
    @required this.gutterWidth,
    @required this.scrollController,
    @required this.lineCount,
    @required this.pausedFrame,
    @required this.breakpoints,
    @required this.executableLines,
    @required this.onPressed,
  });

  final double gutterWidth;
  final ScrollController scrollController;
  final int lineCount;
  final StackFrameAndSourcePosition pausedFrame;
  final List<BreakpointAndSourcePosition> breakpoints;
  final Set<int> executableLines;
  final IntCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bpLineSet = Set.from(breakpoints.map((bp) => bp.line));

    return Container(
      width: gutterWidth,
      color: titleSolidBackgroundColor(Theme.of(context)),
      child: ListView.builder(
        controller: scrollController,
        itemExtent: CodeView.rowHeight,
        itemCount: lineCount,
        itemBuilder: (context, index) {
          final lineNum = index + 1;
          return GutterItem(
            lineNumber: lineNum,
            onPressed: () => onPressed(lineNum),
            isBreakpoint: bpLineSet.contains(lineNum),
            isExecutable: executableLines.contains(lineNum),
            isPausedHere: pausedFrame?.line == lineNum,
          );
        },
      ),
    );
  }
}

class GutterItem extends StatelessWidget {
  const GutterItem({
    Key key,
    @required this.lineNumber,
    @required this.isBreakpoint,
    @required this.isExecutable,
    @required this.isPausedHere,
    @required this.onPressed,
  }) : super(key: key);

  final int lineNumber;

  final bool isBreakpoint;

  final bool isExecutable;

  /// Whether the execution point is currently paused here.
  final bool isPausedHere;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final foregroundColor = theme.isDarkTheme
        ? theme.textTheme.bodyText2.color
        : theme.primaryColor;
    final subtleColor = theme.unselectedWidgetColor;

    const bpBoxSize = 12.0;
    const executionPointIndent = 10.0;

    return InkWell(
      onTap: onPressed,
      child: Container(
        height: CodeView.rowHeight,
        padding: const EdgeInsets.only(right: 4.0),
        child: Stack(
          alignment: AlignmentDirectional.centerStart,
          fit: StackFit.expand,
          children: [
            if (isExecutable || isBreakpoint)
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: bpBoxSize,
                  height: bpBoxSize,
                  child: Center(
                    child: createAnimatedCircleWidget(
                      isBreakpoint ? breakpointRadius : executableLineRadius,
                      isBreakpoint ? foregroundColor : subtleColor,
                    ),
                  ),
                ),
              ),
            Text('$lineNumber', textAlign: TextAlign.end),
            Container(
              padding: const EdgeInsets.only(left: executionPointIndent),
              alignment: Alignment.centerLeft,
              child: AnimatedOpacity(
                duration: defaultDuration,
                curve: defaultCurve,
                opacity: isPausedHere ? 1.0 : 0.0,
                child: Icon(
                  Icons.label,
                  size: defaultIconSize,
                  color: foregroundColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Lines extends StatelessWidget {
  const Lines({
    Key key,
    @required this.scrollController,
    @required this.lines,
    @required this.pausedFrame,
  }) : super(key: key);

  final ScrollController scrollController;
  final List<TextSpan> lines;
  final StackFrameAndSourcePosition pausedFrame;

  @override
  Widget build(BuildContext context) {
    final pausedLine = pausedFrame?.line;

    return ListView.builder(
      controller: scrollController,
      itemExtent: CodeView.rowHeight,
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final lineNum = index + 1;
        return LineItem(
          lineContents: lines[index],
          pausedFrame: pausedLine == lineNum ? pausedFrame : null,
        );
      },
    );
  }
}

class LineItem extends StatefulWidget {
  const LineItem({
    Key key,
    @required this.lineContents,
    this.pausedFrame,
  }) : super(key: key);

  static const _hoverDelay = Duration(milliseconds: 500);
  static const _hoverWidth = 250.0;

  final TextSpan lineContents;
  final StackFrameAndSourcePosition pausedFrame;

  @override
  _LineItemState createState() => _LineItemState();
}

class _LineItemState extends State<LineItem> {
  /// A timer that shows a [HoverCard] with an evaluation result when completed.
  Timer _showTimer;

  /// A timer that removes a [HoverCard] when completed.
  Timer _removeTimer;

  /// Displays the evaluation result of a source code item.
  HoverCard _hoverCard;

  DebuggerController _debuggerController;

  void _onHoverExit() {
    _showTimer?.cancel();
    _removeTimer = Timer(LineItem._hoverDelay, () {
      _hoverCard?.maybeRemove();
    });
  }

  void _onHover(PointerHoverEvent event, BuildContext context) {
    _showTimer?.cancel();
    _removeTimer?.cancel();
    if (!_debuggerController.isPaused.value) return;
    _showTimer = Timer(LineItem._hoverDelay, () async {
      final theme = Theme.of(context);
      _hoverCard?.remove();
      final word = wordForHover(
        event.localPosition.dx,
        widget.lineContents,
        theme.fixedFontStyle,
      );
      if (word != '') {
        try {
          final response = await _debuggerController.evalAtCurrentFrame(word);
          final variable = Variable.fromRef(response);
          await _debuggerController.buildVariablesTree(variable);
          _hoverCard = HoverCard(
            contents: Material(
              child: ExpandableVariable(
                debuggerController: _debuggerController,
                variable: ValueNotifier(variable),
              ),
            ),
            event: event,
            width: LineItem._hoverWidth,
            title: word,
            context: context,
          );
        } catch (_) {
          // Silently fail and don't display a HoverCard.
        }
      }
    });
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _removeTimer?.cancel();
    _hoverCard?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final darkTheme = theme.brightness == Brightness.dark;
    _debuggerController = Provider.of<DebuggerController>(context);

    Widget child;
    if (widget.pausedFrame != null) {
      final column = widget.pausedFrame.column;

      final foregroundColor =
          darkTheme ? theme.textTheme.bodyText2.color : theme.primaryColor;

      // The following constants are tweaked for using the
      // 'Icons.label_important' icon.
      const colIconSize = 13.0;
      const colLeftOffset = -3.0;
      const colBottomOffset = 13.0;
      const colIconRotate = -90 * math.pi / 180;

      // TODO: support selecting text across multiples lines.
      child = Stack(
        children: [
          Row(
            children: [
              // Create a hidden copy of the first column-1 characters of the
              // line as a hack to correctly compute where to place
              // the cursor. Approximating by using column-1 spaces instead
              // of the correct characters and styles would be risky as it leads
              // to small errors if the font is not fixed size or the font
              // styles vary depending on the syntax highlighting.
              // TODO(jacobr): there might be some api exposed on SelectedText
              // to allow us to render this as a proper overlay as similar
              // functionality exists to render the selection handles properly.
              Opacity(
                opacity: 0,
                child: RichText(
                  text: truncateTextSpan(widget.lineContents, column - 1),
                ),
              ),
              Transform.translate(
                offset: const Offset(colLeftOffset, colBottomOffset),
                child: Transform.rotate(
                  angle: colIconRotate,
                  child: Icon(
                    Icons.label_important,
                    size: colIconSize,
                    color: foregroundColor,
                  ),
                ),
              )
            ],
          ),
          _hoverableLine(),
        ],
      );
    } else {
      child = _hoverableLine();
    }

    final backgroundColor = widget.pausedFrame != null
        ? (darkTheme
            ? theme.canvasColor.brighten()
            : theme.canvasColor.darken())
        : null;

    return Container(
      alignment: Alignment.centerLeft,
      height: CodeView.rowHeight,
      color: backgroundColor,
      child: child,
    );
  }

  Widget _hoverableLine() => MouseRegion(
        onExit: (_) => _onHoverExit(),
        onHover: (e) => _onHover(e, context),
        child: SelectableText.rich(
          widget.lineContents,
          scrollPhysics: const NeverScrollableScrollPhysics(),
          maxLines: 1,
        ),
      );
}

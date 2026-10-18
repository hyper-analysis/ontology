import { useEffect, useRef } from "react";
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { basicSetup } from "codemirror";
import { StreamLanguage } from "@codemirror/language";
import type { Span } from "../shared/types";

const language = StreamLanguage.define({
  token(stream) {
    if (stream.sol() && stream.match(/#{1,6}\s+/)) { stream.skipToEnd(); return "heading"; }
    if (stream.sol() && stream.match(/```[^\n]*/)) return "meta";
    if (stream.match(/<\/?[A-Za-z][\w-]*/)) return "tagName";
    if (stream.match("//")) {
      stream.skipToEnd();
      return "comment";
    }
    if (stream.match(/"(?:[^"\\]|\\.)*"/)) return "string";
    if (
      stream.match(
        /\b(?:type|key|unique|alternative|select|from|as|where|let|match|case|limit|order|by|and|or|not|in|exist|only|count|first|every|some|rule|premises|when|observe|produce|within|normalize|same|isTrue|isOccurrence|scrollBy|observeMeaning|observePage)\b/,
      )
    )
      return "keyword";
    if (stream.match(/\b(?:string|number|boolean|timestamp|Ref|Root)\b/))
      return "typeName";
    if (stream.match(/\b(?:true|false|null)\b/)) return "atom";
    if (stream.match(/\b\d+(?:\.\d+)?\b/)) return "number";
    stream.next();
    return null;
  },
});
const theme = EditorView.theme({
  "&": { height: "100%", fontSize: "13px", background: "#fff" },
  ".cm-scroller": {
    fontFamily: '"SFMono-Regular", Consolas, "Liberation Mono", monospace',
    overflow: "auto",
    lineHeight: "1.8",
  },
  ".cm-content": { padding: "20px 0" },
  ".cm-line": { padding: "0 22px" },
  ".cm-gutters": {
    background: "#fff",
    color: "#a1a6b1",
    border: "none",
    minWidth: "44px",
  },
  ".cm-activeLine, .cm-activeLineGutter": { background: "#f5f6fb" },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {
    background: "#e4e5ff !important",
  },
  "&.cm-focused": { outline: "none" },
});

// Compiler offsets are code points; CodeMirror offsets are UTF-16 code units.
export function toEditorOffset(source: string, points: number) {
  return Array.from(source).slice(0, points).join("").length;
}
export function toSourceOffset(source: string, units: number) {
  return Array.from(source.slice(0, units)).length;
}

export function Editor({
  value,
  onChange,
  selection,
  onCursor,
  onRun,
  label,
}: {
  value: string;
  onChange: (value: string) => void;
  selection?: Span | null;
  onCursor?: (offset: number) => void;
  onRun?: () => void;
  label: string;
}) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  const callbacks = useRef({ onChange, onCursor, onRun });
  callbacks.current = { onChange, onCursor, onRun };
  const runBinding = useRef(new Compartment());
  useEffect(() => {
    const editor = new EditorView({
      parent: host.current!,
      state: EditorState.create({
        doc: value,
        extensions: [
          basicSetup,
          language,
          theme,
          EditorView.lineWrapping,
          EditorView.contentAttributes.of({ "aria-label": label }),
          runBinding.current.of(
            keymap.of([
              {
                key: "Mod-Enter",
                run: () => {
                  callbacks.current.onRun?.();
                  return true;
                },
              },
            ]),
          ),
          EditorView.updateListener.of((update) => {
            if (update.docChanged)
              callbacks.current.onChange(update.state.doc.toString());
            if (update.selectionSet)
              callbacks.current.onCursor?.(
                toSourceOffset(
                  update.state.doc.toString(),
                  update.state.selection.main.head,
                ),
              );
          }),
        ],
      }),
    });
    view.current = editor;
    return () => {
      editor.destroy();
      view.current = null;
    };
  }, []);
  useEffect(() => {
    const editor = view.current;
    if (editor && editor.state.doc.toString() !== value)
      editor.dispatch({
        changes: { from: 0, to: editor.state.doc.length, insert: value },
      });
  }, [value]);
  useEffect(() => {
    const editor = view.current;
    if (!editor || !selection) return;
    const source = editor.state.doc.toString();
    const from = toEditorOffset(source, selection.start),
      to = toEditorOffset(source, selection.end);
    editor.dispatch({
      selection: { anchor: from, head: to },
      effects: EditorView.scrollIntoView(from, { y: "center" }),
    });
    editor.focus();
  }, [selection]);
  return <div className="editor" ref={host} />;
}

//! Reactive editor state model shared between native and embedded WgpuMakie panels.

use std::collections::{HashMap, HashSet};
use wgpu_makie_proto::{
    ClientMessage, EditorCommand, EditorDocumentSnapshot, EditorLayerSpec, ServerMessage,
    TimelineState,
};
use wgpu_makie_scene::{BrushSummary, ToolMode};

/// Active tab inside the right-hand plot editor sidebar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditorTab {
    Layers,
    AxesScales,
    Annotations,
    Style,
    Timeline,
    Inspector,
    Code,
}

impl Default for EditorTab {
    fn default() -> Self {
        Self::Layers
    }
}

/// UI actions emitted by editor panels for the host window or embedder to execute.
#[derive(Debug, Clone, PartialEq)]
pub enum EditorAction {
    Send(ClientMessage),
    ResetView,
    ToggleEditor,
    CopyToClipboard(String),
}

/// State model for the modular WgpuMakie plot and layout editor.
#[derive(Debug, Default)]
pub struct EditorModel {
    pub doc: Option<EditorDocumentSnapshot>,
    pub active_tab: EditorTab,
    pub selected_layer: Option<u32>,
    pub selected_elem: Option<(u64, u32)>,
    pub selected_pos: Option<[f64; 3]>,
    pub custom_tooltips: HashMap<(u64, u32), String>,
    pub expr_mode: HashSet<String>,
    pub drafts: HashMap<String, String>,
    pub include_imports: bool,
    pub include_figure: bool,
    pub exported_code: String,
    pub copy_notice_frames: u32,
    pub show_inspector_dock: bool,
    pub add_attr_key: String,
    pub add_attr_expr: String,
    pub add_mapping_role: String,
    pub add_mapping_col: String,
    pub add_scale_role: String,
    pub add_inspector_field: String,
    pub inspector_title_draft: String,
    pub tool_mode: ToolMode,
    pub selected_annotation: Option<u32>,
    pub selected_inset: Option<u32>,
    pub brush: Option<BrushSummary>,
    pub new_ann_text: String,
    pub new_ann_source: String,
    pub timeline: Option<TimelineState>,
    pub html_export_path: String,
    pub html_export_fps: u32,
    pub swap_panel_a: u32,
    pub swap_panel_b: u32,
    pub playback_accum_secs: f64,
    pub undo_stack: Vec<(EditorCommand, EditorCommand)>,
    pub redo_stack: Vec<(EditorCommand, EditorCommand)>,
}

impl EditorModel {
    /// Create a new editor model with inspector dock enabled by default.
    pub fn new() -> Self {
        Self {
            show_inspector_dock: true,
            add_attr_key: "alpha".into(),
            add_attr_expr: "0.8".into(),
            add_mapping_role: "color".into(),
            add_scale_role: "color".into(),
            new_ann_text: "Note".into(),
            new_ann_source: "f".into(),
            html_export_path: "figure.html".into(),
            html_export_fps: 30,
            swap_panel_a: 0,
            swap_panel_b: 1,
            ..Default::default()
        }
    }

    /// Apply an incoming server message if it targets editor, code export, or custom tooltip state.
    pub fn apply_server_message(&mut self, msg: &ServerMessage) -> bool {
        match msg {
            ServerMessage::SyncEditorState { state } => {
                self.exported_code = state.code.clone();
                if let Some(insp) = &state.inspector {
                    self.inspector_title_draft = insp.title.clone().unwrap_or_default();
                }
                if self.selected_layer.is_none()
                    || !state
                        .layers
                        .iter()
                        .any(|l| Some(l.id) == self.selected_layer && !l.is_statement_only)
                {
                    self.selected_layer = state
                        .layers
                        .iter()
                        .find(|l| !l.is_statement_only)
                        .map(|l| l.id)
                        .or_else(|| if state.has_grafico { Some(0) } else { None });
                }
                if self.add_mapping_col.is_empty() {
                    if let Some(first_col) = state.available_columns.first() {
                        self.add_mapping_col = format!(":{first_col}");
                    }
                }
                // Drop drafts for properties whose server values settled so fresh snapshots display cleanly.
                self.drafts.clear();
                self.doc = Some(state.clone());
                true
            }
            ServerMessage::CodeExportReply {
                code,
                include_imports,
                include_figure,
            } => {
                self.exported_code = code.clone();
                self.include_imports = *include_imports;
                self.include_figure = *include_figure;
                true
            }
            ServerMessage::InspectorTooltipReply {
                plot_id,
                element_index,
                text,
            } => {
                self.custom_tooltips
                    .insert((*plot_id, *element_index), text.clone());
                true
            }
            ServerMessage::SyncTimelineState { timeline } => {
                self.timeline = Some(timeline.clone());
                true
            }
            _ => false,
        }
    }

    /// Return `true` when an active timeline is currently playing.
    pub fn is_timeline_playing(&self) -> bool {
        self.timeline
            .as_ref()
            .is_some_and(|t| t.has_timeline && t.playing && t.duration > 0.0)
    }

    /// Advance local timeline playback by `dt_secs`, emitting a seek action at up to 60 Hz.
    pub fn step_playback(&mut self, dt_secs: f64) -> Option<EditorAction> {
        let tl = self.timeline.as_mut()?;
        if !tl.has_timeline || !tl.playing || tl.duration <= 0.0 || dt_secs <= 0.0 {
            return None;
        }
        let speed = tl.speed.max(0.05) as f64;
        let next = tl.current_time + dt_secs * speed;
        if next >= tl.duration {
            if tl.looping {
                tl.current_time = next % tl.duration;
            } else {
                tl.current_time = tl.duration;
                tl.playing = false;
            }
        } else {
            tl.current_time = next;
        }
        self.playback_accum_secs += dt_secs;
        if !tl.playing || self.playback_accum_secs >= 1.0 / 60.0 {
            self.playback_accum_secs = 0.0;
            return Some(EditorAction::Send(ClientMessage::EditorCommand {
                command: EditorCommand::TimelineSeek {
                    time: tl.current_time,
                },
            }));
        }
        None
    }

    /// Record the user's clicked plot element for the Inspector tab and dock.
    pub fn set_selection(&mut self, sel: Option<(u64, u32)>, pos: Option<[f64; 3]>) {
        self.selected_elem = sel;
        self.selected_pos = pos;
    }

    /// Return `true` when the active Grafico inspector uses a custom Julia callback function.
    pub fn has_custom_inspector_callback(&self) -> bool {
        self.doc
            .as_ref()
            .and_then(|d| d.inspector.as_ref())
            .is_some_and(|i| i.has_callback)
    }

    /// Return `true` if a Grafico editable document is attached.
    pub fn has_grafico(&self) -> bool {
        self.doc.as_ref().is_some_and(|d| d.has_grafico)
    }

    /// Return the currently selected layer snapshot when editing a Grafico block plot.
    pub fn active_layer(&self) -> Option<&EditorLayerSpec> {
        let doc = self.doc.as_ref()?;
        let target = self.selected_layer?;
        doc.layers.iter().find(|l| l.id == target)
    }

    /// Emit an editor command, optionally pushing a matching `(forward, inverse)` pair onto undo history.
    pub fn push_command(
        &mut self,
        actions: &mut Vec<EditorAction>,
        forward: EditorCommand,
        inverse: Option<EditorCommand>,
    ) {
        if let Some(inv) = inverse {
            self.undo_stack.push((forward.clone(), inv));
            if self.undo_stack.len() > 64 {
                self.undo_stack.remove(0);
            }
            self.redo_stack.clear();
        }
        actions.push(EditorAction::Send(ClientMessage::EditorCommand {
            command: forward,
        }));
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    pub fn undo(&mut self, actions: &mut Vec<EditorAction>) {
        if let Some((fwd, inv)) = self.undo_stack.pop() {
            actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                command: inv.clone(),
            }));
            self.redo_stack.push((fwd, inv));
        }
    }

    pub fn redo(&mut self, actions: &mut Vec<EditorAction>) {
        if let Some((fwd, inv)) = self.redo_stack.pop() {
            actions.push(EditorAction::Send(ClientMessage::EditorCommand {
                command: fwd.clone(),
            }));
            self.undo_stack.push((fwd, inv));
        }
    }
}

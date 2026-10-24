//! A client's terminal area, and the grid each pane of a layout gets inside it.
//!
//! The geometry repeats what the Mac client does, so a pane Axod sizes before any client shows it
//! already has the grid it will be shown at: `TerminalPaneGeometry.splitLengths` for splits,
//! `UInt32(points * scale)` for a pane's framebuffer, and libghostty's padding and grid
//! arithmetic (`scaledPadding` and `GridSize.update`, both in `f32`).

use serde::{Deserialize, Serialize};

use crate::{LayoutDirection, LayoutNode, ShellId};

/// Sizes beyond these are not a real display.
const MAX_AREA_POINTS: f64 = 100_000.0;
const MAX_BACKING_SCALE: f64 = 8.0;
const MAX_CELL_PIXELS: u32 = 4_096;
const MAX_PADDING_POINTS: u32 = 1_000;
const MAX_DIVIDER_POINTS: f64 = 100.0;
/// Split ratios are clamped like the client's, which never draws a pane thinner than 1%.
const MIN_RATIO: f64 = 0.01;
const MAX_RATIO: f64 = 0.99;
/// libghostty's `font.face.default_dpi` on macOS: one point is one pixel at scale 1.
const DEFAULT_DPI: f32 = 72.0;

/// Where a client draws terminals; the latest client to report one sizes every pane.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(try_from = "ViewportWire", into = "ViewportWire")]
pub struct Viewport {
    terminal_area: Size,
    backing_scale: f64,
    cell: PixelSize,
    padding: Padding,
    divider_thickness: f64,
}

/// A size in points.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// A size in device pixels.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PixelSize {
    pub width: u32,
    pub height: u32,
}

/// Ghostty's `window-padding-x`/`-y`, in whole points as it configures them.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Padding {
    pub top: u32,
    pub bottom: u32,
    pub left: u32,
    pub right: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ViewportWire {
    /// The area panes split, in points.
    terminal_area: Size,
    /// Device pixels per point.
    backing_scale: f64,
    /// One terminal cell, in device pixels.
    cell: PixelSize,
    padding: Padding,
    /// Points between split panes.
    divider_thickness: f64,
}

/// Why a reported viewport was refused.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ViewportError {
    TerminalArea,
    BackingScale,
    Cell,
    Padding,
    DividerThickness,
}

impl std::fmt::Display for ViewportError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            ViewportError::TerminalArea => "viewport terminal area is empty or too large",
            ViewportError::BackingScale => "viewport backing scale is out of range",
            ViewportError::Cell => "viewport cell size is empty or too large",
            ViewportError::Padding => "viewport padding is too large",
            ViewportError::DividerThickness => "viewport divider thickness is out of range",
        })
    }
}

impl TryFrom<ViewportWire> for Viewport {
    type Error = ViewportError;

    fn try_from(wire: ViewportWire) -> Result<Self, Self::Error> {
        let in_range = |value: f64, max: f64| value.is_finite() && value > 0.0 && value <= max;
        let area = wire.terminal_area;
        if !in_range(area.width, MAX_AREA_POINTS) || !in_range(area.height, MAX_AREA_POINTS) {
            return Err(ViewportError::TerminalArea);
        }
        if !in_range(wire.backing_scale, MAX_BACKING_SCALE) {
            return Err(ViewportError::BackingScale);
        }
        let cell = wire.cell;
        if !(1..=MAX_CELL_PIXELS).contains(&cell.width)
            || !(1..=MAX_CELL_PIXELS).contains(&cell.height)
        {
            return Err(ViewportError::Cell);
        }
        let padding = wire.padding;
        if [padding.top, padding.bottom, padding.left, padding.right]
            .iter()
            .any(|side| *side > MAX_PADDING_POINTS)
        {
            return Err(ViewportError::Padding);
        }
        let divider = wire.divider_thickness;
        if !divider.is_finite() || !(0.0..=MAX_DIVIDER_POINTS).contains(&divider) {
            return Err(ViewportError::DividerThickness);
        }
        Ok(Viewport {
            terminal_area: area,
            backing_scale: wire.backing_scale,
            cell,
            padding,
            divider_thickness: divider,
        })
    }
}

impl From<Viewport> for ViewportWire {
    fn from(viewport: Viewport) -> Self {
        ViewportWire {
            terminal_area: viewport.terminal_area,
            backing_scale: viewport.backing_scale,
            cell: viewport.cell,
            padding: viewport.padding,
            divider_thickness: viewport.divider_thickness,
        }
    }
}

/// A terminal grid; both dimensions are at least 1.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GridSize {
    rows: u16,
    columns: u16,
}

impl GridSize {
    pub fn rows(self) -> u16 {
        self.rows
    }

    pub fn columns(self) -> u16 {
        self.columns
    }
}

impl Viewport {
    /// The grid of a pane that fills the whole terminal area, as a new Session's only pane does.
    pub fn full_grid(&self) -> GridSize {
        self.grid(self.terminal_area)
    }

    /// Every pane's grid when `layout` fills the terminal area.
    pub fn grid_sizes(&self, layout: &LayoutNode) -> Vec<(ShellId, GridSize)> {
        let mut sizes = Vec::new();
        self.collect(layout, self.terminal_area, &mut sizes);
        sizes
    }

    fn collect(&self, node: &LayoutNode, size: Size, sizes: &mut Vec<(ShellId, GridSize)>) {
        match node {
            LayoutNode::Pane { shell_id } => sizes.push((*shell_id, self.grid(size))),
            LayoutNode::Split {
                direction,
                ratio,
                first,
                second,
                ..
            } => {
                let (first_size, second_size) = match direction {
                    LayoutDirection::Right => {
                        let (a, b) = self.split_lengths(size.width, *ratio);
                        (Size { width: a, ..size }, Size { width: b, ..size })
                    }
                    LayoutDirection::Down => {
                        let (a, b) = self.split_lengths(size.height, *ratio);
                        (Size { height: a, ..size }, Size { height: b, ..size })
                    }
                };
                self.collect(first, first_size, sizes);
                self.collect(second, second_size, sizes);
            }
        }
    }

    /// `TerminalPaneGeometry.splitLengths`.
    fn split_lengths(&self, axis_length: f64, ratio: f64) -> (f64, f64) {
        let available = (axis_length - self.divider_thickness).max(0.0);
        let first = available * ratio.clamp(MIN_RATIO, MAX_RATIO);
        (first, available - first)
    }

    fn grid(&self, size: Size) -> GridSize {
        // The client's `UInt32(max(0, points * scale))`; `as` truncates and saturates alike.
        let width = (size.width * self.backing_scale).max(0.0) as u32;
        let height = (size.height * self.backing_scale).max(0.0) as u32;
        let dpi = self.backing_scale as f32 * DEFAULT_DPI;
        let scaled = |points: u32| (points as f32 * dpi / DEFAULT_DPI).floor() as u32;
        let padding = self.padding;
        let inner_width = width.saturating_sub(scaled(padding.left) + scaled(padding.right));
        let inner_height = height.saturating_sub(scaled(padding.top) + scaled(padding.bottom));
        let cells = |pixels: u32, cell: u32| {
            ((pixels as f32 / cell as f32) as u32).clamp(1, u32::from(u16::MAX)) as u16
        };
        GridSize {
            rows: cells(inner_height, self.cell.height),
            columns: cells(inner_width, self.cell.width),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn viewport() -> Viewport {
        serde_json::from_value(json!({
            "terminalArea": { "width": 1000.0, "height": 600.0 },
            "backingScale": 2.0,
            "cell": { "width": 16, "height": 34 },
            "padding": { "top": 10, "bottom": 10, "left": 2, "right": 2 },
            "dividerThickness": 1.0
        }))
        .unwrap()
    }

    fn shell(id: i64) -> ShellId {
        ShellId::new(id).unwrap()
    }

    fn grid(rows: u16, columns: u16) -> GridSize {
        GridSize { rows, columns }
    }

    #[test]
    fn a_full_pane_subtracts_scaled_padding() {
        // 2000x1200 px, minus 4+4 and 20+20 px of padding: 1992/16 = 124.5, 1160/34 = 34.1.
        assert_eq!(viewport().full_grid(), grid(34, 124));
    }

    #[test]
    fn splits_share_the_area_minus_the_divider_like_the_client() {
        let a = "82cfd1e8-1cc6-4473-a16d-6f0e77476311".to_owned();
        let b = "9b9e14e0-d1c6-46b8-b289-bab4fda8774f".to_owned();
        let layout = LayoutNode::Split {
            id: a,
            direction: LayoutDirection::Right,
            ratio: 0.5,
            first: Box::new(LayoutNode::Pane { shell_id: shell(1) }),
            second: Box::new(LayoutNode::Split {
                id: b,
                direction: LayoutDirection::Down,
                ratio: 0.25,
                first: Box::new(LayoutNode::Pane { shell_id: shell(2) }),
                second: Box::new(LayoutNode::Pane { shell_id: shell(3) }),
            }),
        };
        // Width 999 pt / 2 = 499.5 pt = 999 px; 999 - 8 = 991 px / 16 = 61.
        // Height 599 pt: 149.75 pt = 299 px -> 259 / 34 = 7; 449.25 pt = 898 px -> 858 / 34 = 25.
        assert_eq!(
            viewport().grid_sizes(&layout),
            [
                (shell(1), grid(34, 61)),
                (shell(2), grid(7, 61)),
                (shell(3), grid(25, 61))
            ]
        );
    }

    #[test]
    fn tiny_panes_keep_one_cell() {
        let viewport: Viewport = serde_json::from_value(json!({
            "terminalArea": { "width": 3.0, "height": 3.0 },
            "backingScale": 1.0,
            "cell": { "width": 16, "height": 34 },
            "padding": { "top": 10, "bottom": 10, "left": 2, "right": 2 },
            "dividerThickness": 1.0
        }))
        .unwrap();
        assert_eq!(viewport.full_grid(), grid(1, 1));
    }

    #[test]
    fn fractional_scales_floor_padding_like_libghostty() {
        let viewport: Viewport = serde_json::from_value(json!({
            "terminalArea": { "width": 100.0, "height": 100.0 },
            "backingScale": 1.5,
            "cell": { "width": 10, "height": 10 },
            "padding": { "top": 3, "bottom": 3, "left": 3, "right": 3 },
            "dividerThickness": 1.0
        }))
        .unwrap();
        // 150 px minus 2 * floor(4.5) = 142 px.
        assert_eq!(viewport.full_grid(), grid(14, 14));
    }

    #[test]
    fn implausible_viewports_are_refused() {
        let base = serde_json::to_value(viewport()).unwrap();
        let cases = [
            (
                "/terminalArea/width",
                json!(0.0),
                ViewportError::TerminalArea,
            ),
            (
                "/terminalArea/height",
                json!(1e9),
                ViewportError::TerminalArea,
            ),
            ("/backingScale", json!(0.0), ViewportError::BackingScale),
            ("/backingScale", json!(9.0), ViewportError::BackingScale),
            ("/cell/width", json!(0), ViewportError::Cell),
            ("/cell/height", json!(5000), ViewportError::Cell),
            ("/padding/left", json!(1001), ViewportError::Padding),
            (
                "/dividerThickness",
                json!(-1.0),
                ViewportError::DividerThickness,
            ),
        ];
        for (pointer, value, expected) in cases {
            let mut wire = base.clone();
            *wire.pointer_mut(pointer).unwrap() = value;
            let parsed: ViewportWire = serde_json::from_value(wire).unwrap();
            assert_eq!(Viewport::try_from(parsed), Err(expected), "{pointer}");
        }
        let mut extra = base;
        extra["unknown"] = json!(1);
        assert!(serde_json::from_value::<Viewport>(extra).is_err());
    }

    #[test]
    fn round_trips() {
        let viewport = viewport();
        let wire = serde_json::to_value(viewport).unwrap();
        assert_eq!(serde_json::from_value::<Viewport>(wire).unwrap(), viewport);
    }
}

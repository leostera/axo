//! Pane layouts: a binary tree of splits whose leaves are the session's panes.

use std::collections::HashSet;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::ShellId;

const MAX_LAYOUT_DEPTH: usize = 64;
const MAX_LAYOUT_NODES: usize = 255;

/// The layout tree exactly as it appears on the wire, before structural validation.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum LayoutNode {
    Pane {
        shell_id: ShellId,
    },
    Split {
        /// A UUID, unique within the tree.
        id: String,
        direction: LayoutDirection,
        /// Share of the first child, in `0.01..=0.99`.
        ratio: f64,
        first: Box<LayoutNode>,
        second: Box<LayoutNode>,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LayoutDirection {
    Right,
    Down,
}

/// Why a layout tree was rejected.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LayoutError {
    /// Deeper than 64 levels or more than 255 nodes.
    TooLarge,
    DuplicateShell,
    InvalidSplitId,
    RatioOutOfRange,
}

impl fmt::Display for LayoutError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            LayoutError::TooLarge => "session layout exceeds its structural limits",
            LayoutError::DuplicateShell => "session layout contains a duplicate shell ID",
            LayoutError::InvalidSplitId => {
                "session layout contains an invalid or duplicate split ID"
            }
            LayoutError::RatioOutOfRange => {
                "session layout split ratio must be between 0.01 and 0.99"
            }
        })
    }
}

impl std::error::Error for LayoutError {}

/// A structurally valid layout: bounded size, each pane at most once, unique UUID split IDs and
/// ratios in range. Whether its panes match a session's open panes is the catalog's concern.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "LayoutNode", into = "LayoutNode")]
pub struct Layout {
    root: LayoutNode,
    shell_ids: HashSet<ShellId>,
}

impl Layout {
    /// A layout containing one pane.
    pub fn single(shell_id: ShellId) -> Layout {
        Layout {
            root: LayoutNode::Pane { shell_id },
            shell_ids: HashSet::from([shell_id]),
        }
    }

    pub fn root(&self) -> &LayoutNode {
        &self.root
    }

    pub fn shell_ids(&self) -> &HashSet<ShellId> {
        &self.shell_ids
    }

    /// The layout restricted to `keep`; a split with one surviving side collapses into it.
    /// `None` if no pane survives.
    pub fn pruned_to(&self, keep: &HashSet<ShellId>) -> Option<Layout> {
        let root = prune(&self.root, keep)?;
        let shell_ids = self.shell_ids.intersection(keep).copied().collect();
        Some(Layout { root, shell_ids })
    }
}

impl TryFrom<LayoutNode> for Layout {
    type Error = LayoutError;

    fn try_from(root: LayoutNode) -> Result<Layout, LayoutError> {
        let mut walk = Walk::default();
        walk.visit(&root, 0)?;
        Ok(Layout {
            root,
            shell_ids: walk.shell_ids,
        })
    }
}

impl From<Layout> for LayoutNode {
    fn from(layout: Layout) -> LayoutNode {
        layout.root
    }
}

#[derive(Default)]
struct Walk {
    nodes: usize,
    shell_ids: HashSet<ShellId>,
    split_ids: HashSet<String>,
}

impl Walk {
    fn visit(&mut self, node: &LayoutNode, depth: usize) -> Result<(), LayoutError> {
        self.nodes += 1;
        if depth > MAX_LAYOUT_DEPTH || self.nodes > MAX_LAYOUT_NODES {
            return Err(LayoutError::TooLarge);
        }
        match node {
            LayoutNode::Pane { shell_id } => {
                if !self.shell_ids.insert(*shell_id) {
                    return Err(LayoutError::DuplicateShell);
                }
            }
            LayoutNode::Split {
                id,
                ratio,
                first,
                second,
                ..
            } => {
                if !is_uuid(id) || !self.split_ids.insert(id.clone()) {
                    return Err(LayoutError::InvalidSplitId);
                }
                if !ratio.is_finite() || !(0.01..=0.99).contains(ratio) {
                    return Err(LayoutError::RatioOutOfRange);
                }
                self.visit(first, depth + 1)?;
                self.visit(second, depth + 1)?;
            }
        }
        Ok(())
    }
}

fn prune(node: &LayoutNode, keep: &HashSet<ShellId>) -> Option<LayoutNode> {
    match node {
        LayoutNode::Pane { shell_id } => keep.contains(shell_id).then(|| node.clone()),
        LayoutNode::Split {
            id,
            direction,
            ratio,
            first,
            second,
        } => match (prune(first, keep), prune(second, keep)) {
            (None, None) => None,
            (Some(remaining), None) | (None, Some(remaining)) => Some(remaining),
            (Some(first), Some(second)) => Some(LayoutNode::Split {
                id: id.clone(),
                direction: *direction,
                ratio: *ratio,
                first: Box::new(first),
                second: Box::new(second),
            }),
        },
    }
}

/// Hyphenated hexadecimal UUID text (any version).
pub fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const A: &str = "00000000-0000-4000-8000-000000000001";
    const B: &str = "00000000-0000-4000-8000-000000000002";

    fn shell(id: i64) -> ShellId {
        ShellId::new(id).unwrap()
    }

    fn parse(value: serde_json::Value) -> Result<Layout, String> {
        serde_json::from_value(value).map_err(|error| error.to_string())
    }

    #[test]
    fn valid_layouts_round_trip_and_list_their_panes() {
        let wire = json!({ "kind": "split", "id": A, "direction": "right", "ratio": 0.5,
            "first": { "kind": "pane", "shellId": 1 },
            "second": { "kind": "split", "id": B, "direction": "down", "ratio": 0.25,
                "first": { "kind": "pane", "shellId": 2 }, "second": { "kind": "pane", "shellId": 3 } } });
        let layout = parse(wire.clone()).unwrap();
        assert_eq!(
            layout.shell_ids(),
            &HashSet::from([shell(1), shell(2), shell(3)])
        );
        assert_eq!(serde_json::to_value(&layout).unwrap(), wire);
    }

    #[test]
    fn structural_violations_are_rejected_while_parsing() {
        let pane = |id: i64| json!({ "kind": "pane", "shellId": id });
        let split = |id: &str, ratio: f64, first, second| json!({ "kind": "split", "id": id, "direction": "right", "ratio": ratio, "first": first, "second": second });
        for (wire, reason) in [
            (split(A, 0.5, pane(1), pane(1)), "duplicate shell ID"),
            (
                split("not-a-uuid", 0.5, pane(1), pane(2)),
                "invalid or duplicate split ID",
            ),
            (
                split(A, 0.5, pane(1), split(A, 0.5, pane(2), pane(3))),
                "invalid or duplicate split ID",
            ),
            (split(A, 1.0, pane(1), pane(2)), "ratio"),
            (pane(0), "not positive"),
            (
                json!({ "kind": "pane", "shellId": 1, "extra": true }),
                "unknown field",
            ),
        ] {
            let error = parse(wire).unwrap_err();
            assert!(error.contains(reason), "{error} should mention {reason}");
        }
    }

    #[test]
    fn oversized_layouts_are_rejected() {
        let mut node = LayoutNode::Pane { shell_id: shell(1) };
        for index in 0..70 {
            node = LayoutNode::Split {
                id: format!("00000000-0000-4000-8000-{index:012}"),
                direction: LayoutDirection::Down,
                ratio: 0.5,
                first: Box::new(LayoutNode::Pane {
                    shell_id: shell(100 + index),
                }),
                second: Box::new(node),
            };
        }
        assert_eq!(Layout::try_from(node), Err(LayoutError::TooLarge));
    }

    #[test]
    fn pruning_collapses_splits_and_keeps_the_pane_set_consistent() {
        let layout = Layout::try_from(LayoutNode::Split {
            id: A.to_owned(),
            direction: LayoutDirection::Right,
            ratio: 0.5,
            first: Box::new(LayoutNode::Pane { shell_id: shell(1) }),
            second: Box::new(LayoutNode::Pane { shell_id: shell(2) }),
        })
        .unwrap();
        let pruned = layout.pruned_to(&HashSet::from([shell(2)])).unwrap();
        assert_eq!(pruned, Layout::single(shell(2)));
        assert!(layout.pruned_to(&HashSet::new()).is_none());
    }
}

use serde::Deserialize;
use crate::ipc::hypr_request_json;

// ─── Data types ───────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct Workspace {
    id:   i64,
    name: String,
}

/// Raw client data as returned by the Hyprland `clients` IPC command.
///
/// `focus_history_id` (Hyprland field: `focusHistoryID`) encodes recency:
/// **0** means the window is currently active; higher values are less recently
/// focused.  The Python implementation used this field to sort windows in MRU
/// order — we replicate that here.
#[derive(Deserialize)]
pub(crate) struct Client {
    class:   String,
    title:   String,
    address: String,
    #[serde(default)]
    hidden:  bool,
    #[serde(default)]
    pinned:  bool,
    workspace: Workspace,
    #[serde(rename = "focusHistoryID")]
    focus_history_id: i64,
}

#[derive(Deserialize)]
struct ActiveWorkspace {
    id: i64,
}

/// `(class, title, address, hidden, focusHistoryID)`
pub type WindowEntry = (String, String, String, bool, i64);

// ─── Public API ───────────────────────────────────────────────────────────────

/// Query Hyprland for all open windows and return them grouped by workspace.
///
/// Group order: active workspace first, then ascending by workspace ID.
/// Within each group: the currently focused window first (fhid == 0), then
/// ascending by `focusHistoryID`.  Pinned windows are excluded.
pub fn get_windows() -> Vec<(String, Vec<WindowEntry>)> {
    let clients: Vec<Client> = hypr_request_json("clients").unwrap_or_default();

    let active_ws_id: Option<i64> = hypr_request_json::<ActiveWorkspace>("activeworkspace")
        .ok()
        .map(|w| w.id);

    group_and_sort(clients, active_ws_id)
}

/// Flatten grouped windows into a single ordered `Vec`.
///
/// The order matches the visual left-to-right, top-to-bottom order of the
/// switcher overlay so that the flat index can be used as the selection index.
pub fn flat_windows(groups: &[(String, Vec<WindowEntry>)]) -> Vec<WindowEntry> {
    groups.iter().flat_map(|(_, entries)| entries.iter().cloned()).collect()
}

// ─── Internal logic (pub(crate) for unit tests) ────────────────────────────

/// Group `clients` by workspace and sort both groups and entries.
///
/// Extracted from [`get_windows`] so it can be tested without a live Hyprland
/// socket.
pub(crate) fn group_and_sort(
    clients: Vec<Client>,
    active_ws_id: Option<i64>,
) -> Vec<(String, Vec<WindowEntry>)> {
    // Build an insertion-order workspace map so we can sort the group order later.
    let mut ws_order: Vec<i64> = Vec::new();
    let mut ws_map: std::collections::HashMap<i64, (String, Vec<Client>)> = Default::default();

    for c in clients {
        if c.pinned { continue; }
        let ws_id   = c.workspace.id;
        let ws_name = c.workspace.name.clone();
        if !ws_map.contains_key(&ws_id) {
            ws_order.push(ws_id);
            ws_map.insert(ws_id, (ws_name, Vec::new()));
        }
        ws_map.get_mut(&ws_id).unwrap().1.push(c);
    }

    // Active workspace comes first; ties broken by ascending workspace ID.
    ws_order.sort_by_key(|&id| (if Some(id) == active_ws_id { 0i64 } else { 1 }, id));

    let mut groups = Vec::new();
    for ws_id in ws_order {
        let (ws_name, mut clients) = ws_map.remove(&ws_id).unwrap();

        // fhid == 0 is the active window — sort it first (key -1).
        // All others sort ascending by fhid, which is MRU order.
        clients.sort_by_key(|c| if c.focus_history_id == 0 { -1i64 } else { c.focus_history_id });

        let entries: Vec<WindowEntry> = clients.into_iter().map(|c| {
            let title = if c.title.is_empty() { "-".to_string() } else { c.title };
            (c.class, title, c.address, c.hidden, c.focus_history_id)
        }).collect();

        groups.push((ws_name, entries));
    }

    groups
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Deserialize a `Client` from a minimal JSON snippet.
    fn client(class: &str, title: &str, addr: &str, ws_id: i64, ws_name: &str, fhid: i64) -> Client {
        serde_json::from_str(&format!(
            r#"{{"class":"{class}","title":"{title}","address":"{addr}",
               "hidden":false,"pinned":false,
               "workspace":{{"id":{ws_id},"name":"{ws_name}"}},
               "focusHistoryID":{fhid}}}"#
        )).unwrap()
    }

    #[test]
    fn empty_client_list_returns_no_groups() {
        let groups = group_and_sort(vec![], None);
        assert!(groups.is_empty());
    }

    #[test]
    fn pinned_windows_are_excluded() {
        let c: Client = serde_json::from_str(
            r#"{"class":"x","title":"x","address":"0x1",
               "hidden":false,"pinned":true,
               "workspace":{"id":1,"name":"1"},
               "focusHistoryID":0}"#,
        ).unwrap();
        let groups = group_and_sort(vec![c], Some(1));
        assert!(groups.is_empty());
    }

    #[test]
    fn active_window_fhid_zero_sorted_first() {
        let clients = vec![
            client("B", "b", "0x2", 1, "1", 2),
            client("A", "a", "0x1", 1, "1", 0), // active
            client("C", "c", "0x3", 1, "1", 1),
        ];
        let groups = group_and_sort(clients, Some(1));
        assert_eq!(groups.len(), 1);
        let entries = &groups[0].1;
        // Expected order: fhid 0 → fhid 1 → fhid 2
        assert_eq!(entries[0].2, "0x1", "active window must be first");
        assert_eq!(entries[1].2, "0x3");
        assert_eq!(entries[2].2, "0x2");
    }

    #[test]
    fn active_workspace_group_comes_first() {
        let clients = vec![
            client("B", "b", "0x2", 2, "2", 1),
            client("A", "a", "0x1", 1, "1", 1),
        ];
        // workspace 2 is active
        let groups = group_and_sort(clients, Some(2));
        assert_eq!(groups[0].0, "2", "active workspace must be first group");
        assert_eq!(groups[1].0, "1");
    }

    #[test]
    fn multiple_workspaces_sorted_ascending_when_none_active() {
        let clients = vec![
            client("C", "c", "0x3", 3, "3", 1),
            client("A", "a", "0x1", 1, "1", 1),
            client("B", "b", "0x2", 2, "2", 1),
        ];
        let groups = group_and_sort(clients, None);
        let ids: Vec<&str> = groups.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(ids, ["1", "2", "3"]);
    }

    #[test]
    fn empty_title_replaced_with_dash() {
        let c = client("App", "", "0x1", 1, "1", 0);
        let groups = group_and_sort(vec![c], Some(1));
        assert_eq!(groups[0].1[0].1, "-");
    }

    #[test]
    fn flat_windows_preserves_group_order() {
        let groups = vec![
            ("ws1".to_string(), vec![
                ("A".to_string(), "a".to_string(), "0x1".to_string(), false, 0i64),
                ("B".to_string(), "b".to_string(), "0x2".to_string(), false, 1i64),
            ]),
            ("ws2".to_string(), vec![
                ("C".to_string(), "c".to_string(), "0x3".to_string(), false, 2i64),
            ]),
        ];
        let flat = flat_windows(&groups);
        assert_eq!(flat.len(), 3);
        assert_eq!(flat[0].2, "0x1");
        assert_eq!(flat[1].2, "0x2");
        assert_eq!(flat[2].2, "0x3");
    }
}

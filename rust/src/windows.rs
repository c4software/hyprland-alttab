use serde::Deserialize;
use crate::ipc::hypr_request_json;

#[derive(Deserialize)]
struct Workspace {
    id: i64,
    name: String,
}

#[derive(Deserialize)]
struct Client {
    class: String,
    title: String,
    address: String,
    #[serde(default)]
    hidden: bool,
    #[serde(default)]
    pinned: bool,
    workspace: Workspace,
    #[serde(rename = "focusHistoryID")]
    focus_history_id: i64,
}

#[derive(Deserialize)]
struct ActiveWorkspace {
    id: i64,
}

pub type WindowEntry = (String, String, String, bool, i64);

pub fn get_windows() -> Vec<(String, Vec<WindowEntry>)> {
    let clients: Vec<Client> = hypr_request_json("clients").unwrap_or_default();

    let active_ws_id: Option<i64> = hypr_request_json::<ActiveWorkspace>("activeworkspace")
        .ok()
        .map(|w| w.id);

    // group by workspace id
    let mut ws_order: Vec<i64> = Vec::new();
    let mut ws_map: std::collections::HashMap<i64, (String, Vec<Client>)> = Default::default();
    for c in clients {
        if c.pinned {
            continue;
        }
        let ws_id   = c.workspace.id;
        let ws_name = c.workspace.name.clone();
        if !ws_map.contains_key(&ws_id) {
            ws_order.push(ws_id);
            ws_map.insert(ws_id, (ws_name, Vec::new()));
        }
        ws_map.get_mut(&ws_id).unwrap().1.push(c);
    }

    // active workspace first, then ascending by id
    ws_order.sort_by_key(|&i| (if Some(i) == active_ws_id { 0i64 } else { 1 }, i));

    let mut groups = Vec::new();
    for ws_id in ws_order {
        let (ws_name, mut clients) = ws_map.remove(&ws_id).unwrap();

        // active window (fhid == 0) first, then ascending — mirror Python's two-pass sort
        clients.sort_by_key(|c| if c.focus_history_id == 0 { -1i64 } else { c.focus_history_id });

        let entries: Vec<WindowEntry> = clients.into_iter().map(|c| {
                let title = if c.title.is_empty() { "-".to_string() } else { c.title };
                (c.class, title, c.address, c.hidden, c.focus_history_id)
            })
            .collect();

        groups.push((ws_name, entries));
    }

    groups
}

pub fn flat_windows(groups: &[(String, Vec<WindowEntry>)]) -> Vec<WindowEntry> {
    groups.iter().flat_map(|(_, entries)| entries.iter().cloned()).collect()
}

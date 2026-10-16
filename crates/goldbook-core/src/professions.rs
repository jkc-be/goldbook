use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, sync::LazyLock};

#[derive(Debug, Deserialize)]
struct Catalog {
    professions: Vec<Profession>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Profession {
    pub id: String,
    pub name: String,
    pub materials: Vec<u32>,
    pub recipes: Vec<u32>,
    pub crafted: Vec<u32>,
}

pub fn professions() -> &'static [Profession] {
    static CATALOG: LazyLock<Catalog> = LazyLock::new(|| {
        serde_json::from_str(include_str!("../../../catalog/professions.json"))
            .expect("generated profession catalog must be valid")
    });
    &CATALOG.professions
}

pub fn profession_items(profession: &str, kind: &str) -> Result<Option<Vec<u32>>, String> {
    if ![
        "all",
        "materials-recipes",
        "materials",
        "recipes",
        "crafted",
    ]
    .contains(&kind)
    {
        return Err("kind must be all, materials-recipes, materials, recipes, or crafted".into());
    }
    if !profession.is_empty() && !professions().iter().any(|p| p.id == profession) {
        return Err("unknown profession".into());
    }
    if profession.is_empty() && kind == "all" {
        return Ok(None);
    }
    let mut ids = BTreeSet::new();
    for p in professions()
        .iter()
        .filter(|p| profession.is_empty() || p.id == profession)
    {
        if ["all", "materials-recipes", "materials"].contains(&kind) {
            ids.extend(&p.materials);
        }
        if ["all", "materials-recipes", "recipes"].contains(&kind) {
            ids.extend(&p.recipes);
        }
        if ["all", "crafted"].contains(&kind) {
            ids.extend(&p.crafted);
        }
    }
    Ok(Some(ids.into_iter().collect()))
}

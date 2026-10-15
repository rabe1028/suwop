//! Ephemeral authority for the one runtime-tested bulk visibility contract.
use super::{Context, DedicatedSession, ERROR, Value, VisibilitySession};
#[derive(Debug, Clone)]
pub(crate) struct LockedVisibilityWriteContract {
    active: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
impl LockedVisibilityWriteContract {
    pub(crate) fn valid(&self) -> bool {
        self.active.load(std::sync::atomic::Ordering::SeqCst)
    }
    fn revoke(&self) {
        self.active
            .store(false, std::sync::atomic::Ordering::SeqCst);
    }
    pub(crate) fn parse(value: &Value) -> Option<Self> {
        (value.get("major").and_then(Value::as_u64) == Some(3)
            && value.get("minor").and_then(Value::as_u64) == Some(3)
            && value.get("patch").and_then(Value::as_u64) == Some(3)
            && value.get("prerelease") == Some(&Value::Null))
        .then(|| Self {
            active: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true)),
        })
    }
}
pub(super) async fn observe(
    ctx: &Context,
    session: &DedicatedSession,
    generation: &std::sync::atomic::AtomicU64,
    expected: u64,
) -> Option<LockedVisibilityWriteContract> {
    let raw = super::guarded(
        ctx,
        generation,
        expected,
        session.request("server/version", "GET", None),
    )
    .await
    .ok()?;
    LockedVisibilityWriteContract::parse(&raw)
}
impl VisibilitySession {
    pub(crate) async fn verify_write_contract(&self, ctx: &Context) -> Result<(), String> {
        let proof = self.session.write_contract.as_ref().ok_or(ERROR)?;
        let result = async {
            self.valid()?;
            if !proof.valid() {
                return Err(ERROR.into());
            }
            let raw = self.json(ctx, "server/version", "GET", None).await?;
            LockedVisibilityWriteContract::parse(&raw).ok_or(ERROR)?;
            self.valid()
        }
        .await;
        if result.is_err() {
            proof.revoke();
        }
        result
    }
}
#[cfg(test)]
mod tests {
    use super::LockedVisibilityWriteContract;
    #[test]
    fn old_proof_revocation_does_not_touch_new_authentication() -> Result<(), String> {
        let raw = serde_json::json!({"major":3,"minor":3,"patch":3,"prerelease":null});
        let old = LockedVisibilityWriteContract::parse(&raw).ok_or("proof")?;
        let captured = old.clone();
        let new = LockedVisibilityWriteContract::parse(&raw).ok_or("proof")?;
        captured.revoke();
        assert!(!old.valid());
        assert!(new.valid());
        Ok(())
    }
    #[test]
    fn only_explicit_stable_release_is_write_authority() -> Result<(), String> {
        let stable = serde_json::json!({"major":3,"minor":3,"patch":3,"prerelease":null});
        assert!(LockedVisibilityWriteContract::parse(&stable).is_some());
        for field in ["major", "minor", "patch", "prerelease"] {
            let mut missing = stable.clone();
            missing.as_object_mut().ok_or("object")?.remove(field);
            assert!(LockedVisibilityWriteContract::parse(&missing).is_none());
        }
        for field in ["major", "minor", "patch"] {
            for value in [
                serde_json::json!("3"),
                serde_json::json!(3.0),
                serde_json::json!(-1),
                serde_json::json!(true),
            ] {
                let mut raw = stable.clone();
                raw[field] = value;
                assert!(LockedVisibilityWriteContract::parse(&raw).is_none());
            }
        }
        for value in [
            serde_json::json!("rc.1"),
            serde_json::json!("beta"),
            serde_json::json!(0),
            serde_json::json!(false),
            serde_json::json!({}),
        ] {
            let mut raw = stable.clone();
            raw["prerelease"] = value;
            assert!(LockedVisibilityWriteContract::parse(&raw).is_none());
        }
        for (major, minor, patch) in [(3, 2, 4), (3, 3, 2), (3, 3, 4), (4, 0, 0)] {
            let raw =
                serde_json::json!({"major":major,"minor":minor,"patch":patch,"prerelease":null});
            assert!(LockedVisibilityWriteContract::parse(&raw).is_none());
        }
        Ok(())
    }
}

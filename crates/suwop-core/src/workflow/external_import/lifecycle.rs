//! Terminate only work which durable storage proves was never submitted.
use super::{ImportJournal, ImportPhase, Runtime, ShellOperation, io};

impl Runtime<'_> {
    pub(in crate::workflow) async fn recover_imports(&mut self) -> Result<(), String> {
        let previous = self.state.external_imports.clone();
        for record in &mut self.state.external_imports {
            *record = if record.phase == ImportPhase::Prepared {
                record.cancel_before_submission()?
            } else {
                record.recover()
            };
        }
        self.persist_import_recovery(previous).await?;
        let operations: std::collections::BTreeSet<_> = self
            .state
            .external_imports
            .iter()
            .map(|record| record.staging_operation.clone())
            .collect();
        for operation in operations {
            self.release_terminal_import_staging(&operation).await?;
        }
        Ok(())
    }

    pub(super) async fn cancel_prepared_imports(&mut self, operation: &str) -> Result<(), String> {
        let previous = self.state.external_imports.clone();
        for record in &mut self.state.external_imports {
            if record.staging_operation == operation && record.phase == ImportPhase::Prepared {
                *record = record.cancel_before_submission()?;
            }
        }
        self.persist_import_recovery(previous).await
    }

    async fn persist_import_recovery(
        &mut self,
        previous: Vec<ImportJournal>,
    ) -> Result<(), String> {
        if self.state.external_imports != previous
            && let Err(error) = self.persist().await
        {
            self.state.external_imports = previous;
            return Err(error);
        }
        Ok(())
    }

    pub(super) async fn release_terminal_import_staging(
        &self,
        operation: &str,
    ) -> Result<(), String> {
        let records: Vec<_> = self
            .state
            .external_imports
            .iter()
            .filter(|record| record.staging_operation == operation)
            .collect();
        if !records.is_empty() && records.iter().all(|record| !record.retains_staged_bytes()) {
            let _: serde_json::Value = io(
                self.ctx,
                ShellOperation::ReleaseImportStaging {
                    operation: operation.into(),
                },
            )
            .await?;
        }
        Ok(())
    }
}

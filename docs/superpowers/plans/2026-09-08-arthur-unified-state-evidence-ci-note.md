# Arthur Unified State Evidence CI Execution Note

The implementation plan is executed with GitHub pull-request CI as the RED/GREEN test runner because the current local execution environment cannot resolve github.com for a repository clone.

This does not change the design. The dedicated `.github/workflows/arthur-state-contract.yml` workflow exists only to execute `tests/arthur-state-contract.tests.ps1` on the implementation branch so the test can be observed failing before `scripts/arthur-state-contract.ps1` is created, then observed passing after the minimal implementation is added.

No firmware build, Candidate dispatch, flash, or release is part of this test workflow.

<!-- Links -->

[introduction]: #introduction

[design-related-smells]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells
[genserver-envy]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/genserver_envy
[agent-obsession]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/agent_obsession
[unsupervised-process]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/unsupervised_process
[large-messages]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/large_messages
[unrelated-multi-clause-function]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/unrelated_multi_clause_function
[complex-extractions-in-clauses]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/complex_extractions_in_clauses
[using-exceptions-for-control-flow]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/using_exceptions_for_control_flow
[untested-polymorphic-behaviors]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/untested_polymorphic_behaviors
[code-organization-by-process]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/code_organization_by_process
[large-code-generation-by-macros]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/large_code_generation_by_macros
[data-manipulation-by-migration]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/data_manipulation_by_migration
[using-app-configuration-for-libraries]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/using_app_configuration_for_libraries
[compile-time-global-configuration]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/compile_time_global_configuration
[use-instead-of-import]: https://github.com/labd2m/ExSmell-Gold/tree/main/design_related_smells/use_instead_of_import

[low-level-concerns-smells]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells
[working-with-invalid-data]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/working_with_invalid_data
[complex-branching]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/complex_branching
[complex-else-clauses-in-with]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/complex_else_clauses_in_with
[alternative-return-types]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/alternative_return_types
[accessing-non-existent-mapstruct-fields]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/accessing_non_existent_map_struct_fields
[speculative-assumptions]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/speculative_assumptions
[modules-with-identical-names]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/modules_with_identical_names
[unnecessary-macros]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/unnecessary_macros
[dynamic-atom-creation]: https://github.com/labd2m/ExSmell-Gold/tree/main/low_level_concerns_smells/dynamic_atom_creation

[traditional-smells]: https://github.com/labd2m/ExSmell-Gold/tree/main/traditional_smells
[smell-free]: https://github.com/labd2m/ExSmell-Gold/tree/main/smell_free

[about]: #about
[acknowledgments]: #acknowledgments

# ExSmell-Gold

## Introduction

ExSmell-Gold is a curated dataset of Elixir code smells designed to support research, benchmarking, and experimentation with automated code smell detection techniques.

The dataset was created based on the code smell catalog maintained by Lucas Vegi:

https://github.com/lucasvegi/Elixir-Code-Smells

ExSmell-Gold contains **3,500 Elixir source code examples**, including:

- **1,750 examples containing code smells**
- **1,750 examples without intentionally introduced code smells**

The smelly examples cover **35 code smells**, with **50 examples per smell**.

The examples were initially generated using **Claude Sonnet 4.6** and subsequently reviewed, refined, and validated by researchers to ensure alignment with the definitions provided in the original catalog.

The goal of ExSmell-Gold is to provide a publicly available benchmark for:

- Code smell detection
- Multi-class smell classification
- Multi-label smell classification
- Smell localization
- Evaluation of static analysis tools
- Evaluation of Machine Learning models
- Evaluation of Large Language Models (LLMs)

## Dataset Quality

A representative subset of the dataset was manually reviewed by two researchers.

The validation process confirmed a high level of agreement regarding the presence and classification of smells. During the review process, additional smells identified in some examples were also documented.

For the non-smelly subset, a statistical validation was performed using a representative sample. After correcting the identified issues, the subset achieved an estimated correctness of approximately **97.4%**, considering a **90% confidence level** and a **5% margin of error**.

Additional details regarding dataset construction and validation will be presented in a forthcoming research publication.

## Repository Organization

The dataset is organized according to the categories defined in the original catalog.

### Design-related smells

Examples for each smell can be found in the following directories:

- [GenServer Envy][genserver-envy]
- [Agent Obsession][agent-obsession]
- [Unsupervised Process][unsupervised-process]
- [Large Messages][large-messages]
- [Unrelated Multi-Clause Function][unrelated-multi-clause-function]
- [Complex Extractions in Clauses][complex-extractions-in-clauses]
- [Using Exceptions for Control Flow][using-exceptions-for-control-flow]
- [Untested Polymorphic Behaviors][untested-polymorphic-behaviors]
- [Code Organization by Process][code-organization-by-process]
- [Large Code Generation by Macros][large-code-generation-by-macros]
- [Data Manipulation by Migration][data-manipulation-by-migration]
- [Using App Configuration for Libraries][using-app-configuration-for-libraries]
- [Compile-Time Global Configuration][compile-time-global-configuration]
- ["Use" Instead of "Import"][use-instead-of-import]

### Low-level concerns smells

Examples for each smell can be found in the following directories:

- [Working with Invalid Data][working-with-invalid-data]
- [Complex Branching][complex-branching]
- [Complex Else Clauses in With][complex-else-clauses-in-with]
- [Alternative Return Types][alternative-return-types]
- [Accessing Non-Existent Map/Struct Fields][accessing-non-existent-mapstruct-fields]
- [Speculative Assumptions][speculative-assumptions]
- [Modules with Identical Names][modules-with-identical-names]
- [Unnecessary Macros][unnecessary-macros]
- [Dynamic Atom Creation][dynamic-atom-creation]

### Traditional Smells

Traditional code smells adapted to the Elixir ecosystem can be found in:

- [Traditional Smells][traditional-smells]

### Non-Smelly Examples

Examples intentionally created without code smells can be found in:

- [Smell Free][smell-free]

## Intended Usage

ExSmell-Gold can be used as:

- A benchmark dataset for code smell detection.
- A ground-truth dataset for evaluating LLMs.
- A training resource for machine learning models.
- A reference collection of code smell examples in Elixir.
- Educational material for discussing software quality and maintainability in Elixir projects.

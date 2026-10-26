//! Operation-specific authoring and analysis budgets. Equal numeric values do
//! not imply interchangeable meanings or independently verified VM acceptance.
pub const raw_arguments = 256;
pub const raw_array_elements = 256;
pub const calli_arguments = 256;
pub const argument_mask_bits = 256;
pub const ratio_factors = 16;
pub const stack_words = 1024;
pub const static_references = 128;

pub const syntax_tokens = 32768;
pub const syntax_nodes = 8192;
pub const syntax_depth = 256;
pub const lowering_depth = 256;
pub const resolution_depth = 256;
pub const ir_depth = 1024;
pub const factory_nodes = 100_000;
pub const dependency_visits = 100_000;

pub const abi_schema_depth = 16;
pub const abi_schema_nodes = 256;
pub const abi_array_elements = 256;
pub const abi_dynamic_bytes = 8192;
pub const abi_descriptor_bytes = 1024;
pub const abi_tape_words = 256;
pub const abi_plan_visits = 4096;
pub const abi_call_bytes = 16384;

pub const analysis_states = 4096;
pub const analysis_steps = 131072;
// Static analysis can inspect a broader frame than source authoring accepts.
pub const analysis_frame_words = 1024;
pub const analysis_description_bytes = 4096;
pub const source_bytes = 256 * 1024;
pub const generated_source_bytes = 512 * 1024;
pub const open_documents = 128;
pub const indentation_width = 32;

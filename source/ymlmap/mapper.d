// TODO: Consider collecting errors instead of just printing to stderr.
// TODO: Add support for Nullable complex types if needed (e.g., Nullable!Nested).

/**
 * Acknowledgements:
 * This file uses elements and techniques heavily inspired by the cli-d package by Sebastiaan de Schaetzen.
 * The code can by found at https://github.com/seeseemelk/cli-d
 */

/++
 + This module provides a way to map a YAML node from DYAML to a D struct
 + using attribute-based field discovery.
 +
 + $(P
 + Features:
 +  - Maps YAML mappings to struct fields annotated with `@Field`.
 +  - `@Field` can infer the YAML name from the D field name (`@Field T member;`) or accept an explicit one (`@Field("yaml_name") T member;`).
 +  - Fields marked `@Required` trigger validation errors if missing in YAML.
 +  - Supports nested structs, arrays (`T[]`), and associative arrays (`V[K]`).
 +  - Handles basic YAML types (scalars, null) and recursively maps structs within arrays/AAs.
 +  - Reports validation and mapping errors to stderr.
 + )
 +
 + $(P
 + Limitations:
 +  - AA keys (`K`) must be basic types convertible from YAML keys (usually string).
 +  - Direct mapping of a root sequence to an array type (`map!SomeType[](...)`) is not supported.
 +  - Error reporting is basic (stderr).
 + )
 +
 + Example: $(REF_INNER_CODE example.d)
 +/
module ymlmap.mapper;

import std.stdio : stderr;
import std.typecons : Nullable;
import std.traits : hasUDA, getUDAs, isIntegral, isFloatingPoint, isSomeString, isArray, isAssociativeArray, isAggregateType, getSymbolsByUDA;
import std.datetime : SysTime;
import std.conv : to;

import dyaml.node;
import dyaml.exception;
import dyaml.parser;
import dyaml.stdsumtype;

import ymlmap.attributes;

// --- Internal State and Helpers ---

private struct ParseState(C)
{
    static assert(is(C == struct), "Internal Error: ParseState instantiated with non-struct type: " ~ C.stringof);

    // Node root; // Maybe not needed? Context passed down via tags.

    /// Global failure flag for this mapping operation
    bool failed;

    /// Tracks required fields for *this* C instance
    mixin RequireStruct!C requires;
}

private mixin template RequireStruct(C)
{
    static foreach (memberSymbol; getSymbolsByUDA!(C, Required))
    {
        mixin("bool " ~ __traits(identifier, memberSymbol) ~ " = false;");
    }
}

// --- Type Classification Templates ---

/// Checks if T is a basic scalar/null type directly convertible by dyaml's .as
private template isBasicYamlType(T)
{
    enum isBasicYamlType = is(T == YAMLNull) || is(T == bool) || isIntegral!T || isFloatingPoint!T || isSomeString!T
        || is(T == ubyte[]) || is(T == SysTime)
        || (is(T : Nullable!U, U) && isBasicYamlType!U); // Allow Nullable basis types
}

/// Checks if T is a type we know how to map (basic or struct)
private template isMappableType(T)
{
    enum isMappableType = isBasicYamlType!T || is(T == struct);
}

/// Determines the expected YAML field name from @Field attribute or D member name.
private string getExpectedYamlName(C, alias MemberSymbol)() //@safe pure nothrow
{
    alias FieldAttrs = getUDAs!(__traits(getMember, C, MemberSymbol), Field);
    static assert(FieldAttrs.length == 1,
        "Internal Error: Expected one @Field for '" ~ MemberSymbol ~ "'");

    alias FieldAttr = FieldAttrs[0];
    
    // Check if the UDA applied was the type itself (@Field) vs. an instance (@Field() or @Field("name"))
    static if (is(FieldAttr == Field))
    {
        return MemberSymbol;
    }
    else // UDA was applied as "@Field()" or "@Field("name")"
    {
        string nameFromAttr = FieldAttr.name;
        
        // Use the name from the attribute only if it's non-null and non-empty
        if (nameFromAttr !is null && nameFromAttr.length > 0)
        {
            return nameFromAttr;
        }
        else // Fallback for @Field() or @Field("")
        {
            return MemberSymbol;
        }
    }
}

// --- Core Mapping Logic ---

/++
 + Maps a YAML `root` Node to an instance of struct `C`. $(RED This is the main entry point.)
 +
 + Params:
 +   root = The dyaml Node to map from (result of `Loader.load()`). Must be a Mapping node.
 +   successfulValidation = Output param. `true` if mapping succeeds *and* all `@Required` fields found, `false` otherwise.
 +
 + Returns: Instance of `C` populated from YAML. May be partially populated on error.
 +/
public C map(C)(Node root, ref bool successfulValidation)
{
    validateStruct!C();
    C c;
    ParseState!C state;

    // --- Root Node Handling ---
    if (root.type != NodeType.mapping)
    {
        // Only allow mapping from a YAML map directly to a struct
        static if (is(C : E[], E)) // Check if C itself is an array type
        {
            stderr.writeln("Error: Mapping root sequences directly to array types (e.g., map!(MyStruct[])) is not supported.");
        }
        else // C is struct or other unsupported type
        {
            stderr.writeln("Error: Root YAML node must be a Mapping (key-value pairs) to map to struct '", C.stringof, "', but got '", root.type, "'.");
        }
        state.failed = true;
    }
    else
    {
        // --- Main Mapping Loop ---
        foreach (Node.Pair pair; root.mapping())
        {
            string keyTag; // The key from the YAML mapping
            try
            {
                keyTag = pair.key.as!string;
                if (keyTag is null) throw new Exception("YAML key evaluated to null string");
            }
            catch (Exception e)
            {
                stderr.writeln("Error mapping struct '", C.stringof, "': YAML mapping contains unusable key '", pair.key, "' (must be convertible to string). Error: ", e.msg);
                state.failed = true;
                break; // Stop processing this mapping on bad key
            }

            auto valueNode = Node(pair.value, keyTag); // Create Node for value, tagged w/ key
            mapNode!C(state, c, valueNode, keyTag); // Process this key-value pair against 'c'

            if (state.failed) break; // Stop processing if a node mapping failed critically
        }
    }

    // --- Final Validation ---
    bool requiredFieldsMet = checkRequires!C(state, root);
    // final success = no errors during mapping AND all required fields were present
    successfulValidation = !state.failed && requiredFieldsMet;
    return c;
}


// --- Recursive Mapping Helpers ---

/++
 + Maps a single generic YAML `itemNode` (scalar, sequence, map) to the target D type `E`.
 + Called internally for array elements and AA values. Handles basic types and recursive struct mapping.
 + Params:
 +   E = The target D type for the item.
 +   C = The type of the immediate parent struct whose ParseState is being used.
 +   state = $(B ref) to the `ParseState` of the parent struct `C` (used to propagate `failed` flag).
 +   itemNode = The `dyaml.Node` representing the YAML item.
 +   itemTag = A string describing the item's context (e.g., "parent.key", "parent[i]") for errors.
 +   itemValidated = $(B ref) bool set to `true` if THIS item was successfully mapped (structure/type OK), independent of `state.failed`.
 + Returns: The mapped value of type `E`. Default initialized on error.
 +/
private E mapItem(E, C)(ref ParseState!C state, Node itemNode, string itemTag, ref bool itemValidated)
{
    // Ensure state propagation works correctly
    static assert(is(typeof(state) == ParseState!C), "Internal Error: mapItem received incorrect state type.");
    static assert(!is(E == void), "Internal Error: mapItem instantiated with void element type.");

    E itemValue;
    itemValidated = false;

    try
    {
        // --- Basic Type Handling ---
        static if (isBasicYamlType!E)
        {
            if (itemNode.type == NodeType.null_)
            {
                static if (is(E : Nullable!U, U)) // Target is Nullable!Basic
                {
                    itemValue = E.init;
                    itemValidated = true;
                }
                else // Target is non-nullable basic
                {
                    stderr.writeln("Warning: Assigning YAML null to non-nullable basic type '", E.stringof, "' for item '", itemTag, "'. Using default value.");
                    itemValue = E.init;
                    itemValidated = true; // Allow default assignment as success
                }
            }
            else // YAML node is not null
            {
                itemValue = itemNode.as!E; // Direct conversion (can throw)
                itemValidated = true;
            }
        }
        // --- Struct Handling ---
        else static if (is(E == struct))
        {
            if (itemNode.type != NodeType.mapping)
            {
                stderr.writeln("Error mapping item '", itemTag, "': Expected a YAML Mapping for struct type '", E.stringof, "', but got '", itemNode.type, "'.");
                state.failed = true;
                // itemValidated remains false
            }
            else
            {
                // Recursively map the item node to struct E.
                itemValue = map!E(itemNode, itemValidated); // itemValidated is set by recursive map!
                // If recursive call failed validation/mapping, propagate failure to outer state.
                if (!itemValidated) state.failed = true;
            }
        }
        // --- Unsupported Type Handling ---
        else
        {
            stderr.writeln("Error: Cannot map YAML item '", itemTag, "' to unsupported target type '", E.stringof, "'.");
            state.failed = true;
            itemValidated = false;
        }
    }
    catch (Exception e) // Catch errors from .as!E or potentially deeper
    {
        stderr.writeln("Error converting YAML item '", itemTag, "' to type '", E.stringof, "': ", e.msg);
        state.failed = true;
        itemValidated = false;
    }

    return itemValue;
}

/++
 + Processes a single key-value pair from a YAML mapping against the target struct `c`.
 + Finds the matching `@Field` in `c` based on `nodeTag` (the YAML key) and delegates
 + mapping the `node` (the YAML value) to the correct field type handler.
 +/
private void mapNode(C)(ref ParseState!C state, ref C c, Node node, string nodeTag)
{
    // Sanity check - should be guaranteed by caller map()
    static assert(is(C == struct));

    foreach (member; __traits(allMembers, C))
    {
        // Check if this D field has the @Field attribute
        static if (hasUDA!(__traits(getMember, c, member), Field))
        {
            // Determine the YAML name this field expects
            string expectedYamlName = getExpectedYamlName!(C, member);

            // If the current YAML key matches the name expected by this field...
            if (expectedYamlName == nodeTag)
            {
                // Found the target D field (`member`) for the YAML key (`nodeTag`).
                alias MemberType = typeof(__traits(getMember, c, member));

                try
                {
                    // --- Branch based on the D MEMBER type and YAML NODE type ---

                    // Case 1: D member is an Array T[] (and not string)
                    static if (is(MemberType : E[], E) && !isSomeString!MemberType)
                    {
                        if (node.type != NodeType.sequence)
                        {
                            stderr.writeln("Error mapping field '", member, "' ('", MemberType.stringof, "'): Expected a YAML Sequence for array type, but got '", node.type, "' for key '", nodeTag, "'.");
                            state.failed = true;
                        }
                        else
                        {
                            static if (isMappableType!E) // Check if element type E is mappable
                            {
                                auto arr = __traits(getMember, c, member);
                                arr.length = 0;
                                int i = 0;
                                foreach (Node elementNode; node.sequence())
                                {
                                    bool elementValidated = false;
                                    string nestedTag = nodeTag ~ "[" ~ i.to!string ~ "]";
                                    auto value = mapItem!(E, C)(state, elementNode, nestedTag, elementValidated);
                                    if (state.failed) break; // Stop if item mapping failed
                                    arr ~= value;
                                    i++;
                                }

                                if (!state.failed) __traits(getMember, c, member) = arr;
                            }
                            else
                            {
                                stderr.writeln("Error mapping field '", member, "': Array element type '", E.stringof, "' is not a supported mappable type (basic or struct).");
                                state.failed = true;
                            }
                        }
                    }

                    // Case 2: D member is an Associative Array V[K]
                    else static if (is(MemberType : V[K], K, V))
                    {
                        if (node.type != NodeType.mapping)
                        {
                            stderr.writeln("Error mapping field '", member, "' ('", MemberType.stringof, "'): Expected a YAML Mapping for associative array type, but got '", node.type, "' for key '", nodeTag, "'.");
                            state.failed = true;
                        }
                        else
                        {
                            // Check key type K support
                            static assert(isBasicYamlType!K || isSomeString!K, "Associative array key type '" ~ K.stringof ~ "' in field '" ~ member ~ "' is not supported (must be basic YAML type).");
                            // Value type V can be basic or struct (handled by mapItem)
                            static if (isMappableType!V)
                            {
                                auto mapAA = __traits(getMember, c, member);
                                mapAA = null;

                                foreach (Node.Pair pair; node.mapping())
                                {
                                    // Convert YAML key to D key type K
                                    K key;
                                    try { key = pair.key.as!K; }
                                    catch (Exception e)
                                    {
                                        stderr.writeln("Error converting YAML key '", pair.key, "' to type '", K.stringof, "' for AA field '", member, "': ", e.msg);
                                        state.failed = true;
                                        break;
                                    }

                                    // Map YAML value to D value type V using mapItem
                                    auto valueNode = pair.value;
                                    bool valueValidated = false;
                                    string valueTag = nodeTag ~ "." ~ pair.key.as!string;
                                    auto value = mapItem!(V, C)(state, valueNode, valueTag, valueValidated);
                                    if (state.failed) break; // Stop if value mapping failed

                                    mapAA[key] = value;
                                }

                                if (!state.failed) __traits(getMember, c, member) = mapAA;
                            }
                            else
                            {
                                stderr.writeln("Error mapping field '", member, "': Associative array value type '", V.stringof, "' is not a supported mappable type (basic or struct).");
                                state.failed = true;
                            }
                        }
                    }

                    // Case 3: D member is a nested Struct
                    else static if (is(MemberType == struct))
                    {
                        if (node.type != NodeType.mapping)
                        {
                            stderr.writeln("Error mapping field '", member, "' ('", MemberType.stringof, "'): Expected a YAML Mapping for struct type, but got '", node.type, "' for key '", nodeTag, "'.");
                            state.failed = true;
                        }
                        else
                        {
                            bool nestedValidated = false;
                            auto value = map!MemberType(node, nestedValidated);

                            if (!nestedValidated) state.failed = true;
                            if (!state.failed) __traits(getMember, c, member) = value;
                        }
                    }

                    // Case 4: D member is a Basic YAML Type
                    else static if (isBasicYamlType!MemberType)
                    {
                        if (node.type == NodeType.sequence || node.type == NodeType.mapping)
                        {
                            stderr.writeln("Error mapping field '", member, "' ('", MemberType.stringof, "'): Expected a YAML Scalar or Null for basic type, but got '", node.type, "' for key '", nodeTag, "'.");
                            state.failed = true;
                        }
                        else // Handle scalar or null
                        {
                            if (node.type == NodeType.null_ && !is(MemberType : Nullable!U, U))
                            {
                                stderr.writeln("Warning: Assigning YAML null to non-nullable field '", member, "' ('", MemberType.stringof, "'). Using default value.");
                                __traits(getMember, c, member) = MemberType.init; // Assign default
                            }
                            else
                            {
                                try
                                {
                                    __traits(getMember, c, member) = node.as!MemberType; // Direct conversion
                                }
                                catch (Exception e) // Catch dyaml .as errors specifically
                                {
                                    stderr.writeln("Error converting YAML value for key '", nodeTag, "' to field '", member,"' ('", MemberType.stringof, "'): ", e.msg);
                                    state.failed = true;
                                }
                            }
                        }
                    }

                    // Case 5: Unsupported D Member Type
                    else
                    {
                        stderr.writeln("Error mapping field '", member, "': Target type '", MemberType.stringof, "' is not supported by the YAML mapper.");
                        state.failed = true;
                    }

                    // --- Mark required field if mapping was attempted (even if error occurred within) ---
                    static if (hasUDA!(__traits(getMember, c, member), Required))
                    {
                        mixin("state.requires." ~ member ~ " = true;");
                    }

                }
                catch (Exception e) // Catch unexpected errors during mapping logic
                {
                    stderr.writeln("Internal Error during mapping field '", member, "' (YAML key '", nodeTag, "'): ", e.msg);
                    state.failed = true;
                }

                // Found and processed the matching member for this nodeTag, exit inner loop
                return;
            }
            // else: YAML key nodeTag != expectedYamlName for this member, continue loop
        }
        // else: member does not have @Field UDA, ignore it
    } // End foreach member

    // If loop finishes, YAML key `nodeTag` didn't match any @Field member. This is usually okay.
    // stderr.writeln("Debug: YAML key '", nodeTag, "' ignored (no matching @Field in '", C.stringof, "').");
}


/++
 + Checks `state.requires` flags to ensure all fields marked `@Required` in struct `C`
 + were encountered during mapping. Sets `state.failed = true` and reports errors if any are missing.
 + Returns: `true` if all required fields were found, `false` otherwise.
 +/
private bool checkRequires(C)(ref ParseState!C state, Node parentContext)
{
    bool allFound = true;
    string parentIdentifier = (parentContext.tag.length == 0) ? "<root>" : parentContext.tag;

    static foreach (member; __traits(allMembers, C))
    {
        // Check if this member is Required AND if its flag in state.requires is false
        static if (hasUDA!(__traits(getMember, C, member), Required))
        {
            if (!mixin("state.requires." ~ member))
            {
                allFound = false;

                string expectedYamlName = getExpectedYamlName!(C, member);

                // Mark overall failure
                stderr.writeln("Validation Error: Required field '", expectedYamlName, "' (mapped to D field '", member, "') is missing from YAML object '", parentIdentifier, "'.");
                state.failed = true;
            }
        }
    }

    return allFound;
}


/++
 + Performs compile-time validation on the struct `C` used for mapping.
 +/
private void validateStruct(C)() @safe pure nothrow
{
    static assert(is(C == struct), "Type '" ~ C.stringof ~ "' provided to map() must be a struct.");

    // Ensure all members marked @Required also have @Field
    static foreach (memberSymbol; getSymbolsByUDA!(C, Required))
    {
        static assert(hasUDA!(memberSymbol, Field),
            "Field '" ~ __traits(identifier, memberSymbol) ~ "' in struct '" ~ C.stringof ~ "' is marked @Required but is missing @Field.");
    }

    static foreach (member; __traits(allMembers, C))
    {{
        static if (hasUDA!(__traits(getMember, C, member), Field))
        {
            alias memberType = typeof(__traits(getMember, C, member));

            static assert(isMappableType!memberType || isArray!memberType || isAssociativeArray!memberType,
                "Field '" ~ member ~ "' has unsupported type '" ~ memberType.stringof ~ "' for YAML mapping.");
        }
    }}
}

// --- Example Usage ---
/// (Embedded example showing basic usage)
/// $(CODE_NAME example.d)
unittest // Keep main separate, use unittest for inline example
{
    import std.file : write, remove;
    import dyaml.loader;

    enum yamlContent = q{
        name: Example Config
        age: 42
        nested_obj:
          detail: Nested Detail String
        tags:
          - tag1
          - value2
        mapped_items:
          keyA:
            detail: Detail A
          keyB:
            detail: Detail B
    };
    write("temp_config.yml", yamlContent);

    struct Nested { @Field string detail; } // Define structs locally for unittest
    struct MyConfig
    {
        @Field("name") @Required string name;
        @Field int age;
        @Field Nested nested_obj;
        @Field string[] tags;
        @Field Nested[string] mapped_items;
        @Field bool optional_flag; // Field not in YAML
    }

    scope(exit) remove("temp_config.yml");

    bool success;
    auto root = Loader.fromFile("temp_config.yml").load();
    auto config = map!MyConfig(root, success);

    assert(success, "Mapping failed validation");
    assert(config.name == "Example Config");
    assert(config.age == 42);
    assert(config.nested_obj.detail == "Nested Detail String");
    assert(config.tags == ["tag1", "value2"]);
    assert(config.mapped_items["keyA"].detail == "Detail A");
    assert(config.mapped_items["keyB"].detail == "Detail B");
    assert(config.optional_flag == false); // Default initialized

    // Test missing required
    enum badYaml = q{ age: 99 };
    write("bad_config.yml", badYaml);
    scope(exit) remove("bad_config.yml");
    auto badRoot = Loader.fromFile("bad_config.yml").load();
    auto badConfig = map!MyConfig(badRoot, success);
    assert(!success, "Mapping should have failed validation (missing name)");

    // Test type mismatch
    enum typeYaml = q{
        name: OK
        age: "not a number"
    };
    write("type_config.yml", typeYaml);
    scope(exit) remove("type_config.yml");
    auto typeRoot = Loader.fromFile("type_config.yml").load();
    auto typeConfig = map!MyConfig(typeRoot, success);
    assert(!success, "Mapping should have failed validation (bad age type)");

    // Test mapping struct where scalar expected
    enum structScalarYaml = q{
        name: OK
        age: {a: 1}
    };
    write("structScalar_config.yml", structScalarYaml);
    scope(exit) remove("structScalar_config.yml");
    auto ssRoot = Loader.fromFile("structScalar_config.yml").load();
    auto ssConfig = map!MyConfig(ssRoot, success);
    assert(!success, "Mapping should have failed (YAML map for basic type age)");

    // Test mapping sequence where AA expected
    enum seqAAYaml = q{
        name: OK
        mapped_items: [a,b]
    };
    write("seqAA_config.yml", seqAAYaml);
    scope(exit) remove("seqAA_config.yml");
    auto seqAARoot = Loader.fromFile("seqAA_config.yml").load();
    auto seqAAConfig = map!MyConfig(seqAARoot, success);
    assert(!success, "Mapping should have failed (YAML seq for AA type mapped_items)");
}

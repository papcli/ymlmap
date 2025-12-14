module ymlmap.attributes;

/++
 + The `Field` attribute is used to specify the name of a field in the YAML file.
 +/
public struct Field
{
    /// The name of the field in the YAML file. If not provided, the D field name is used.
    string name;

    public this(string name) @safe pure nothrow
    {
        this.name = name;
    }
}

/+
 + The `Required` attribute is used to specify that a field is required in the YAML file.
 +/
public struct Required {}

public struct Key
{
    /// The name of the mapping key
    string name;
}

/++
 + The `Constructor` attribute is used to specify a constructor function for a field.
 + It is used to convert the YAML node to the desired type.
 +/
public struct Constructor(T)
{
    import dyaml.node : Node;

    public alias ConstructorFunc = T function(Node input);

    public ConstructorFunc constructor;
}

public auto constructor(FT)(FT func)
{
    import std.traits : isFunctionPointer, ReturnType;

    static assert(isFunctionPointer!FT, "Error: Argument to `constructor` should be a function pointer, not: " ~ FT.stringof);
    
    alias RType = ReturnType!FT;
    static assert(!is(RType == void), "Error: Converter needs to be of the return type of the field, not `void`");
    
    return Constructor!RType(func);
}

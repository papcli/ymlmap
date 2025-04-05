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
module ymlmap.util;

import std.meta : Alias, AliasSeq, anySatisfy;
import std.traits : hasUDA, getUDAs, hasMember, getSymbolsByUDA;

template value(C, alias m)
{
    alias value = __traits(getMember, C, m);
}

template value(alias c, alias m)
{
    alias value = __traits(getMember, c, m);
}

template hasUDAV(C, alias m, T)
{
    alias hasUDAV = hasUDA!(value!(C, m), T);
}

template hasUDAV(C, alias m, alias t)
{
    alias hasUDAV = hasUDA!(value!(C, m), t);
}

template hasUDAV(alias c, alias m, alias t)
{
    alias hasUDA = hasUDA!(value!(c, m), t);
}

template hasField(alias E)
{
    alias hasField = hasUDA!(E, Field);
}

template hasField(C, alias E)
{
    alias hasField = Alias!(hasUDA!(value!(C, E), Field));
}

template getField(alias E)
{
    alias getField = Alias!(getUDAs!(E, Field)[0]);
}

template getField(C, alias e)
{
    alias getField = Alias!(getUDAs!(value!(C, e), Field)[0]);
}

bool hasNamedField(C)(string name)
{
    static foreach (member; __traits(allMembers, C))
    {
        if (hasField!(C, member) && getField!(C, member).name == name)
        {
            return true;
        }
    }

    return false;
}

template isRequired(alias E)
{
    alias isRequired = Alias!(hasUDA!(E, Required));
}

template isRequired(C, alias e)
{
    alias isRequired = Alias!(isRequired!(value!(C, e)));
}

template isNamedField(alias e)
{
    alias isNamedField = Alias!(getField!(e).name.length > 0);
}

template isNamedField(alias C, alias e)
{
    alias isNamedField = isNamedField!(value!(C, e));
}

template isUnnamedField(alias C, alias e)
{
    alias isUnnamedField = Alias!(hasField!(value!(C, e)) && !isNamedField!(C, e));
}

template hasNamedFields(C, members...)
{
    static if (isNamedField!(C, members[0]))
    {
        alias hasNamedFields = Alias!true;
    }
    else static if (members.length == 1)
    {
        alias hasNamedFields = isNamedField!(C, members[0]);
    }
    else
    {
        alias hasNamedFields = hasNamedFields!(C, members[1..$]);
    }
}

template hasNamedFields(C, member)
{
    alias hasNamedFields = isNamedField!(C, member[i]);
}

alias hasNamedFields(C) = hasNamedFields!(C, __traits(allMembers, C));

template hasUnnamedFields(C, members...)
{
    static if (!isNamedField!(C, members[0]))
    {
        alias hasUnnamedFields = Alias!true;
    }
    else static if (members.length == 1)
    {
        alias hasUnnamedFields =  Alias!(!isNamedField!(C, members[0]));
    }
    else
    {
        alias hasUnnamedFields = hasUnnamedFields!(C, members[1..$]);
    }
}

alias hasUnnamedFields(C) = hasUnnamedFields!(C, __traits(allMembers, C));

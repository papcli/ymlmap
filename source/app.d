import std.stdio;
import ymlmap;
import dyaml;

struct Test
{
    @Field("a")
    int a;
    @Field("c")
    string b;
    @Field
    bool hello;
}

struct Holder
{
    @Field("items")
    @Key("id")
    Item[] items;
}

struct Item
{
    string id;
}

void main()
{
    Node node = Loader.fromFile("test.yml").load();
    bool validated;
    auto test = map!Test(node, validated);

    writeln(test.a);
    writeln(test.b);
}

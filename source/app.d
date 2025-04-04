import std.stdio;

import std;
import ymlmap = ymlmap : mapper = map, Field = Field;
import dyaml;

struct Stage
{
    @Field
    string name;
}

struct Container
{
    @Field
    int something;

    @Field("other")
    string other;

    @Field("hello")
    string[] hello;

    @Field("stages")
    Stage[string] stages;
}

void main()
{
	writeln("Edit source/app.d to start your project.");

	Node root = Loader.fromFile("test.yml").load();
	bool validated;
	Container c = mapper!Container(root, validated);

	writeln(c.something);
	writeln(c.other);
	writeln(c.hello);

	foreach (pair; c.stages.byKeyValue)
	{
        writeln(pair.key);
        writeln(pair.value.name);
    }
}

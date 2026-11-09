import { Kilograms, WellnessScale } from "@cadencia/athlete/Measures";
import { WellnessDeclaration } from "@cadencia/athlete/Wellness";
import { Day } from "@cadencia/kernel/Calendar/Day";
import { Paragraph } from "@cadencia/kernel/Text";
import { Minutes } from "@cadencia/kernel/Training/Units";
import { SessionId } from "@cadencia/planning/Plan/Session.id";
import * as Option from "effect/Option";
import * as Record from "effect/Record";
import * as Schema from "effect/Schema";
import { FieldValidation } from "foldkit";
import { Rule } from "foldkit/fieldValidation";

/**
 * The domain values the forms ask for, decoded from the text their controls
 * hold with the domain's own schemas: a field passes its rule exactly when the
 * command will accept it.
 */
const MinutesText = Schema.FiniteFromString.pipe(Schema.decodeTo(Minutes));
const ParagraphText = Schema.Trim.pipe(Schema.decodeTo(Paragraph));
const ScaleText = Schema.FiniteFromString.pipe(Schema.decodeTo(WellnessScale));
const KilogramsText = Schema.FiniteFromString.pipe(Schema.decodeTo(Kilograms));

const isBlank = (text: string) => text.trim() === "";

/** A field's text: what its control holds, and whether it passes its rules. */
export const TextField = FieldValidation.Field(Schema.String);
export type TextField = typeof TextField.Type;
const blank = (value = ""): TextField => FieldValidation.NotValidated({ value });

export const MOVE_RULES = {
  sessionId: FieldValidation.makeRules({ required: "Elige una sesión.", rules: [Rule.fromSchema(SessionId, "Esa sesión no es válida.")] }),
  toDay: FieldValidation.makeRules({ required: "Elige el día nuevo.", rules: [Rule.fromSchema(Day, "Ese día no es válido.")] }),
};

export const REQUIREMENT_RULES = {
  day: FieldValidation.makeRules({ required: "Elige el día.", rules: [Rule.fromSchema(Day, "Ese día no es válido.")] }),
  maxMinutes: FieldValidation.makeRules({
    isEmpty: isBlank,
    rules: [Rule.fromSchema(MinutesText, "Un número entero de minutos, de 0 a 1440.")],
  }),
  instructions: FieldValidation.makeRules({
    required: "Escribe qué necesitas ese día.",
    isEmpty: isBlank,
    rules: [Rule.fromSchema(ParagraphText, "La nota es demasiado larga (4000 caracteres como máximo).")],
  }),
};

const scaleRules = FieldValidation.makeRules({ rules: [Rule.fromSchema(ScaleText, "De 1 a 4.")] });

export const DECLARATION_RULES = {
  mood: scaleRules,
  motivation: scaleRules,
  soreness: scaleRules,
  fatigue: scaleRules,
  weight: FieldValidation.makeRules({ isEmpty: isBlank, rules: [Rule.fromSchema(KilogramsText, "Entre 20 y 350 kg.")] }),
  comments: FieldValidation.makeRules({
    isEmpty: isBlank,
    rules: [Rule.fromSchema(ParagraphText, "El comentario es demasiado largo (4000 caracteres como máximo).")],
  }),
};

/** A form's fields by name, and the rules each must pass. */
type Form<Name extends string> = { readonly [N in Name]: TextField };
type FormRules<Name extends string> = { readonly [N in Name]: FieldValidation.Rules<string> };

export const MoveForm = Schema.Struct({ sessionId: TextField, toDay: TextField });
export const RequirementForm = Schema.Struct({ day: TextField, maxMinutes: TextField, instructions: TextField });
export const DeclarationForm = Schema.Struct({
  mood: TextField,
  motivation: TextField,
  soreness: TextField,
  fatigue: TextField,
  weight: TextField,
  comments: TextField,
});
export type DeclarationForm = typeof DeclarationForm.Type;

export const emptyMove: Form<keyof typeof MOVE_RULES> = { sessionId: blank(), toDay: blank() };
export const emptyRequirement = (day: Day): Form<keyof typeof REQUIREMENT_RULES> => ({
  day: blank(day),
  maxMinutes: blank(),
  instructions: blank(),
});
export const emptyDeclaration: DeclarationForm = {
  mood: blank(),
  motivation: blank(),
  soreness: blank(),
  fatigue: blank(),
  weight: blank(),
  comments: blank(),
};

/** One field edited: checked against its rules as the athlete types. */
export const edit = <Name extends string>(form: Form<Name>, rules: FormRules<Name>, name: Name, value: string): Form<Name> => ({
  ...form,
  [name]: FieldValidation.validate(rules[name])(value),
});

/** Every field checked, as on submit: a required field left untouched shows its message too. */
export const check = <Name extends string>(form: Form<Name>, rules: FormRules<Name>): Form<Name> =>
  Record.map(rules, (fieldRules, name) => FieldValidation.validate(fieldRules)(form[name].value));

const decode =
  <A>(schema: Schema.Codec<A, string>) =>
  (field: TextField): Option.Option<A> =>
    Schema.decodeUnknownOption(schema)(field.value);

/** An optional field: blank is `null`; anything else must decode. */
const decodeOptional =
  <A>(schema: Schema.Codec<A, string>) =>
  (field: TextField): Option.Option<A | null> =>
    isBlank(field.value) ? Option.some(null) : decode(schema)(field);

/** What the move form sends, once every field holds what the command accepts. */
export const moveOf = (form: Form<keyof typeof MOVE_RULES>) =>
  Option.all({ sessionId: decode(SessionId)(form.sessionId), toDay: decode(Day)(form.toDay) });

/** What the day's requirement sends, once every field holds what the command accepts. */
export const requirementOf = (form: Form<keyof typeof REQUIREMENT_RULES>) =>
  Option.all({
    day: decode(Day)(form.day),
    instructions: decode(ParagraphText)(form.instructions),
    maxMinutes: decodeOptional(MinutesText)(form.maxMinutes),
  });

/** What the wellness form saves: the fields filled in, each as Intervals takes it. */
export const declarationOf = (form: DeclarationForm): Option.Option<WellnessDeclaration> =>
  Option.all({
    mood: decodeOptional(ScaleText)(form.mood),
    motivation: decodeOptional(ScaleText)(form.motivation),
    soreness: decodeOptional(ScaleText)(form.soreness),
    fatigue: decodeOptional(ScaleText)(form.fatigue),
    weight: decodeOptional(KilogramsText)(form.weight),
    comments: decodeOptional(ParagraphText)(form.comments),
  }).pipe(
    Option.map(Record.filter((value) => value !== null)),
    Option.flatMap(Schema.decodeUnknownOption(WellnessDeclaration)),
  );

package main

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestTypeCatalog(t *testing.T) {
	tx := testTransaction(t)
	h := newHandler(tx, "secret", "catalog-test", 5*time.Second)
	create := func(body string) int64 {
		t.Helper()
		var ref eventTypeRef
		if err := json.Unmarshal(request(t, h, "POST", "/event-types", "secret", body, 201), &ref); err != nil {
			t.Fatal(err)
		}
		return ref.ID
	}
	active := create(`{"code":"catalog_case_b","name":"Каталог","description":"Исследование",
        "fields":[
            {"field_key":"temperature","label":"Температура","data_type":"number","sort_order":20},
            {"field_key":"pressure","label":"Давление","data_type":"number","sort_order":20,"unit_code":"bar",
                "description":"На устье","is_required":true,"min_number":0,"max_number":9007199254740993.125},
            {"field_key":"method","label":"Метод","data_type":"select","sort_order":5},
            {"field_key":"legacy","label":"Прежнее поле","data_type":"text","min_length":2,"max_length":40}
        ],
        "options":[{"field_key":"method","code":"z","label":"Вручную","sort_order":10},
                   {"field_key":"method","code":"a","label":"Автоматически","sort_order":10},
                   {"field_key":"method","code":"old","label":"Прежний","sort_order":0}]
    }`)
	empty := create(`{"code":"catalog_case_a","name":"Каталог"}`)
	archived := create(`{"code":"catalog_case_c","name":"Каталог",
      "fields":[{"field_key":"method","label":"Вид","data_type":"select"}],
      "options":[{"field_key":"method","code":"foreign","label":"Другой тип"}]}`)
	if _, err := tx.Exec("UPDATE event_field_options SET is_archived=true WHERE event_type_id=$1 AND code='old'", active); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec("UPDATE event_type_fields SET is_archived=true WHERE event_type_id=$1 AND field_key='legacy'", active); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec("UPDATE event_types SET is_archived=true WHERE id=$1", archived); err != nil {
		t.Fatal(err)
	}

	t.Run("list", func(t *testing.T) {
		for _, tc := range []struct {
			suffix string
			want   []string
		}{
			{"", []string{"catalog_case_a", "catalog_case_b"}},
			{"?include_archived=true", []string{"catalog_case_a", "catalog_case_b", "catalog_case_c"}},
		} {
			var rows []struct {
				Code     string
				Archived bool `json:"is_archived"`
			}
			if err := json.Unmarshal(request(t, h, "GET", "/event-types"+tc.suffix, "secret", "", 200), &rows); err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, row := range rows {
				if strings.HasPrefix(row.Code, "catalog_case_") {
					got = append(got, row.Code)
					if row.Archived != (row.Code == "catalog_case_c") {
						t.Errorf("archive flag for %s", row.Code)
					}
				}
			}
			if !slices.Equal(got, tc.want) {
				t.Fatalf("catalog %q: %v", tc.suffix, got)
			}
		}
	})
	t.Run("form", func(t *testing.T) {
		type option struct {
			Code, Label string
			Archived    bool `json:"is_archived"`
		}
		type field struct {
			fieldDefinition
			Archived bool `json:"is_archived"`
			Options  []option
		}
		type definition struct {
			ID                      int64
			Code, Name, Description string
			Archived                bool `json:"is_archived"`
			Fields                  []field
		}
		get := func(id int64, suffix string) definition {
			t.Helper()
			var d definition
			b := request(t, h, "GET", fmt.Sprintf("/event-types/%d%s", id, suffix), "secret", "", 200)
			if err := json.Unmarshal(b, &d); err != nil {
				t.Fatal(err)
			}
			return d
		}
		d := get(active, "")
		if d.ID != active || d.Code != "catalog_case_b" || d.Name != "Каталог" || d.Description != "Исследование" || len(d.Fields) != 3 {
			t.Fatalf("definition: %+v", d)
		}
		method, pressure := d.Fields[0], d.Fields[1]
		if method.Key != "method" || !slices.Equal(method.Options, []option{{"a", "Автоматически", false}, {"z", "Вручную", false}}) {
			t.Fatalf("select: %+v", method)
		}
		if pressure.Key != "pressure" || pressure.Type != "number" || pressure.Label != "Давление" || !pressure.Required ||
			pressure.Unit == nil || *pressure.Unit != "bar" || pressure.Description == nil || *pressure.Description != "На устье" ||
			pressure.MinNumber == nil || pressure.MinNumber.String() != "0" || pressure.MaxNumber == nil || pressure.MaxNumber.String() != "9007199254740993.125" ||
			pressure.Options == nil || len(pressure.Options) != 0 || d.Fields[2].Key != "temperature" {
			t.Fatalf("pressure or field order: %+v", d.Fields)
		}
		all := get(active, "?include_archived=true")
		if len(all.Fields) != 4 || all.Fields[0].Key != "legacy" || !all.Fields[0].Archived ||
			all.Fields[0].MinLength == nil || *all.Fields[0].MinLength != 2 || all.Fields[0].MaxLength == nil || *all.Fields[0].MaxLength != 40 ||
			len(all.Fields[1].Options) != 3 || all.Fields[1].Options[0] != (option{"old", "Прежний", true}) {
			t.Fatalf("archived metadata: %+v", all.Fields)
		}
		if fields := get(empty, "").Fields; fields == nil || len(fields) != 0 {
			t.Fatalf("expected empty fields array: %v", fields)
		}
		if !get(archived, "").Archived {
			t.Error("archived type unavailable to existing card")
		}
	})
}

func TestCatalogInput(t *testing.T) {
	h := newHandler(nil, "secret", "test", time.Second)
	request(t, h, "GET", "/event-types/0", "secret", "", 400)
	request(t, h, "GET", "/event-types?include_archived=oops", "secret", "", 400)
	request(t, h, "GET", "/event-types/1?include_archived=true&include_archived=false", "secret", "", 400)
	request(t, h, "GET", "/event-types", "wrong", "", 401)
}

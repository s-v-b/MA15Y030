--
-- PostgreSQL database dump
--

-- Dumped from database version 13.8
-- Dumped by pg_dump version 16.4 (Ubuntu 16.4-0ubuntu0.24.04.2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pagila; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA pagila;


--
-- Name: SCHEMA pagila; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA pagila IS 'Standard pagila schema';


--
-- Name: mpaa_rating; Type: TYPE; Schema: pagila; Owner: -
--

CREATE TYPE pagila.mpaa_rating AS ENUM (
    'G',
    'PG',
    'PG-13',
    'R',
    'NC-17'
);


--
-- Name: year; Type: DOMAIN; Schema: pagila; Owner: -
--

CREATE DOMAIN pagila.year AS integer
	CONSTRAINT year_check CHECK (((VALUE >= 1901) AND (VALUE <= 2155)));


--
-- Name: _group_concat(text, text); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila._group_concat(text, text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
SELECT CASE
  WHEN $2 IS NULL THEN $1
  WHEN $1 IS NULL THEN $2
  ELSE $1 || ', ' || $2
END
$_$;


--
-- Name: film_in_stock(integer, integer); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila.film_in_stock(p_film_id integer, p_store_id integer, OUT p_film_count integer) RETURNS SETOF integer
    LANGUAGE sql
    AS $_$
     SELECT inventory_id
     FROM inventory
     WHERE film_id = $1
     AND store_id = $2
     AND inventory_in_stock(inventory_id);
$_$;


--
-- Name: film_not_in_stock(integer, integer); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila.film_not_in_stock(p_film_id integer, p_store_id integer, OUT p_film_count integer) RETURNS SETOF integer
    LANGUAGE sql
    AS $_$
    SELECT inventory_id
    FROM inventory
    WHERE film_id = $1
    AND store_id = $2
    AND NOT inventory_in_stock(inventory_id);
$_$;


--
-- Name: get_customer_balance(integer, timestamp without time zone); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila.get_customer_balance(p_customer_id integer, p_effective_date timestamp without time zone) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
       --#OK, WE NEED TO CALCULATE THE CURRENT BALANCE GIVEN A CUSTOMER_ID AND A DATE
       --#THAT WE WANT THE BALANCE TO BE EFFECTIVE FOR. THE BALANCE IS:
       --#   1) RENTAL FEES FOR ALL PREVIOUS RENTALS
       --#   2) ONE DOLLAR FOR EVERY DAY THE PREVIOUS RENTALS ARE OVERDUE
       --#   3) IF A FILM IS MORE THAN RENTAL_DURATION * 2 OVERDUE, CHARGE THE REPLACEMENT_COST
       --#   4) SUBTRACT ALL PAYMENTS MADE BEFORE THE DATE SPECIFIED
DECLARE
    v_rentfees DECIMAL(5,2); --#FEES PAID TO RENT THE VIDEOS INITIALLY
    v_overfees INTEGER;      --#LATE FEES FOR PRIOR RENTALS
    v_payments DECIMAL(5,2); --#SUM OF PAYMENTS MADE PREVIOUSLY
BEGIN
    SELECT COALESCE(SUM(film.rental_rate),0) INTO v_rentfees
    FROM film, inventory, rental
    WHERE film.film_id = inventory.film_id
      AND inventory.inventory_id = rental.inventory_id
      AND rental.rental_date <= p_effective_date
      AND rental.customer_id = p_customer_id;

    SELECT COALESCE(SUM(IF((rental.return_date - rental.rental_date) > (film.rental_duration * '1 day'::interval),
        ((rental.return_date - rental.rental_date) - (film.rental_duration * '1 day'::interval)),0)),0) INTO v_overfees
    FROM rental, inventory, film
    WHERE film.film_id = inventory.film_id
      AND inventory.inventory_id = rental.inventory_id
      AND rental.rental_date <= p_effective_date
      AND rental.customer_id = p_customer_id;

    SELECT COALESCE(SUM(payment.amount),0) INTO v_payments
    FROM payment
    WHERE payment.payment_date <= p_effective_date
    AND payment.customer_id = p_customer_id;

    RETURN v_rentfees + v_overfees - v_payments;
END
$$;


--
-- Name: inventory_held_by_customer(integer); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila.inventory_held_by_customer(p_inventory_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_customer_id INTEGER;
BEGIN

  SELECT customer_id INTO v_customer_id
  FROM rental
  WHERE return_date IS NULL
  AND inventory_id = p_inventory_id;

  RETURN v_customer_id;
END $$;


--
-- Name: inventory_in_stock(integer); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila.inventory_in_stock(p_inventory_id integer) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_rentals INTEGER;
    v_out     INTEGER;
BEGIN
    -- AN ITEM IS IN-STOCK IF THERE ARE EITHER NO ROWS IN THE rental TABLE
    -- FOR THE ITEM OR ALL ROWS HAVE return_date POPULATED

    SELECT count(*) INTO v_rentals
    FROM rental
    WHERE inventory_id = p_inventory_id;

    IF v_rentals = 0 THEN
      RETURN TRUE;
    END IF;

    SELECT COUNT(rental_id) INTO v_out
    FROM inventory LEFT JOIN rental USING(inventory_id)
    WHERE inventory.inventory_id = p_inventory_id
    AND rental.return_date IS NULL;

    IF v_out > 0 THEN
      RETURN FALSE;
    ELSE
      RETURN TRUE;
    END IF;
END $$;


--
-- Name: last_day(timestamp without time zone); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila.last_day(timestamp without time zone) RETURNS date
    LANGUAGE sql IMMUTABLE STRICT
    AS $_$
  SELECT CASE
    WHEN EXTRACT(MONTH FROM $1) = 12 THEN
      (((EXTRACT(YEAR FROM $1) + 1) operator(pg_catalog.||) '-01-01')::date - INTERVAL '1 day')::date
    ELSE
      ((EXTRACT(YEAR FROM $1) operator(pg_catalog.||) '-' operator(pg_catalog.||) (EXTRACT(MONTH FROM $1) + 1) operator(pg_catalog.||) '-01')::date - INTERVAL '1 day')::date
    END
$_$;


--
-- Name: last_updated(); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila.last_updated() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.last_update = CURRENT_TIMESTAMP;
    RETURN NEW;
END $$;


--
-- Name: customer_customer_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.customer_customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: customer; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.customer (
    customer_id integer DEFAULT nextval('pagila.customer_customer_id_seq'::regclass) NOT NULL,
    store_id smallint NOT NULL,
    first_name character varying(45) NOT NULL,
    last_name character varying(45) NOT NULL,
    email character varying(50),
    address_id smallint NOT NULL,
    activebool boolean DEFAULT true NOT NULL,
    create_date date DEFAULT ('now'::text)::date NOT NULL,
    last_update timestamp without time zone DEFAULT now(),
    active integer
);


--
-- Name: rewards_report(integer, numeric); Type: FUNCTION; Schema: pagila; Owner: -
--

CREATE FUNCTION pagila.rewards_report(min_monthly_purchases integer, min_dollar_amount_purchased numeric) RETURNS SETOF pagila.customer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
DECLARE
    last_month_start DATE;
    last_month_end DATE;
rr RECORD;
tmpSQL TEXT;
BEGIN

    /* Some sanity checks... */
    IF min_monthly_purchases = 0 THEN
        RAISE EXCEPTION 'Minimum monthly purchases parameter must be > 0';
    END IF;
    IF min_dollar_amount_purchased = 0.00 THEN
        RAISE EXCEPTION 'Minimum monthly dollar amount purchased parameter must be > $0.00';
    END IF;

    last_month_start := CURRENT_DATE - '3 month'::interval;
    last_month_start := to_date((extract(YEAR FROM last_month_start) || '-' || extract(MONTH FROM last_month_start) || '-01'),'YYYY-MM-DD');
    last_month_end := LAST_DAY(last_month_start);

    /*
    Create a temporary storage area for Customer IDs.
    */
    CREATE TEMPORARY TABLE tmpCustomer (customer_id INTEGER NOT NULL PRIMARY KEY);

    /*
    Find all customers meeting the monthly purchase requirements
    */

    tmpSQL := 'INSERT INTO tmpCustomer (customer_id)
        SELECT p.customer_id
        FROM payment AS p
        WHERE DATE(p.payment_date) BETWEEN '||quote_literal(last_month_start) ||' AND '|| quote_literal(last_month_end) || '
        GROUP BY customer_id
        HAVING SUM(p.amount) > '|| min_dollar_amount_purchased || '
        AND COUNT(customer_id) > ' ||min_monthly_purchases ;

    EXECUTE tmpSQL;

    /*
    Output ALL customer information of matching rewardees.
    Customize output as needed.
    */
    FOR rr IN EXECUTE 'SELECT c.* FROM tmpCustomer AS t INNER JOIN customer AS c ON t.customer_id = c.customer_id' LOOP
        RETURN NEXT rr;
    END LOOP;

    /* Clean up */
    tmpSQL := 'DROP TABLE tmpCustomer';
    EXECUTE tmpSQL;

RETURN;
END
$_$;


--
-- Name: group_concat(text); Type: AGGREGATE; Schema: pagila; Owner: -
--

CREATE AGGREGATE pagila.group_concat(text) (
    SFUNC = pagila._group_concat,
    STYPE = text
);


--
-- Name: category_category_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.category_category_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: category; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.category (
    category_id integer DEFAULT nextval('pagila.category_category_id_seq'::regclass) NOT NULL,
    name character varying(25) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: film_category; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.film_category (
    film_id smallint NOT NULL,
    category_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: actor_actor_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.actor_actor_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: actor; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.actor (
    actor_id integer DEFAULT nextval('pagila.actor_actor_id_seq'::regclass) NOT NULL,
    first_name character varying(45) NOT NULL,
    last_name character varying(45) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: film_film_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.film_film_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: film; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.film (
    film_id integer DEFAULT nextval('pagila.film_film_id_seq'::regclass) NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    release_year pagila.year,
    language_id smallint NOT NULL,
    original_language_id smallint,
    rental_duration smallint DEFAULT 3 NOT NULL,
    rental_rate numeric(4,2) DEFAULT 4.99 NOT NULL,
    length smallint,
    replacement_cost numeric(5,2) DEFAULT 19.99 NOT NULL,
    rating pagila.mpaa_rating DEFAULT 'G'::pagila.mpaa_rating,
    last_update timestamp without time zone DEFAULT now() NOT NULL,
    special_features text[],
    fulltext tsvector NOT NULL
);


--
-- Name: film_actor; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.film_actor (
    actor_id smallint NOT NULL,
    film_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: actor_info; Type: VIEW; Schema: pagila; Owner: -
--

CREATE VIEW pagila.actor_info AS
 SELECT a.actor_id,
    a.first_name,
    a.last_name,
    pagila.group_concat(DISTINCT (((c.name)::text || ': '::text) || ( SELECT pagila.group_concat((f.title)::text) AS group_concat
           FROM ((pagila.film f
             JOIN pagila.film_category fc_1 ON ((f.film_id = fc_1.film_id)))
             JOIN pagila.film_actor fa_1 ON ((f.film_id = fa_1.film_id)))
          WHERE ((fc_1.category_id = c.category_id) AND (fa_1.actor_id = a.actor_id))
          GROUP BY fa_1.actor_id))) AS film_info
   FROM (((pagila.actor a
     LEFT JOIN pagila.film_actor fa ON ((a.actor_id = fa.actor_id)))
     LEFT JOIN pagila.film_category fc ON ((fa.film_id = fc.film_id)))
     LEFT JOIN pagila.category c ON ((fc.category_id = c.category_id)))
  GROUP BY a.actor_id, a.first_name, a.last_name;


--
-- Name: address_address_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.address_address_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: address; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.address (
    address_id integer DEFAULT nextval('pagila.address_address_id_seq'::regclass) NOT NULL,
    address character varying(50) NOT NULL,
    address2 character varying(50),
    district character varying(20) NOT NULL,
    city_id smallint NOT NULL,
    postal_code character varying(10),
    phone character varying(20) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: city_city_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.city_city_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: city; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.city (
    city_id integer DEFAULT nextval('pagila.city_city_id_seq'::regclass) NOT NULL,
    city character varying(50) NOT NULL,
    country_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: country_country_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.country_country_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: country; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.country (
    country_id integer DEFAULT nextval('pagila.country_country_id_seq'::regclass) NOT NULL,
    country character varying(50) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: customer_list; Type: VIEW; Schema: pagila; Owner: -
--

CREATE VIEW pagila.customer_list AS
 SELECT cu.customer_id AS id,
    (((cu.first_name)::text || ' '::text) || (cu.last_name)::text) AS name,
    a.address,
    a.postal_code AS "zip code",
    a.phone,
    city.city,
    country.country,
        CASE
            WHEN cu.activebool THEN 'active'::text
            ELSE ''::text
        END AS notes,
    cu.store_id AS sid
   FROM (((pagila.customer cu
     JOIN pagila.address a ON ((cu.address_id = a.address_id)))
     JOIN pagila.city ON ((a.city_id = city.city_id)))
     JOIN pagila.country ON ((city.country_id = country.country_id)));


--
-- Name: film_list; Type: VIEW; Schema: pagila; Owner: -
--

CREATE VIEW pagila.film_list AS
 SELECT film.film_id AS fid,
    film.title,
    film.description,
    category.name AS category,
    film.rental_rate AS price,
    film.length,
    film.rating,
    pagila.group_concat((((actor.first_name)::text || ' '::text) || (actor.last_name)::text)) AS actors
   FROM ((((pagila.category
     LEFT JOIN pagila.film_category ON ((category.category_id = film_category.category_id)))
     LEFT JOIN pagila.film ON ((film_category.film_id = film.film_id)))
     JOIN pagila.film_actor ON ((film.film_id = film_actor.film_id)))
     JOIN pagila.actor ON ((film_actor.actor_id = actor.actor_id)))
  GROUP BY film.film_id, film.title, film.description, category.name, film.rental_rate, film.length, film.rating;


--
-- Name: inventory_inventory_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.inventory_inventory_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inventory; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.inventory (
    inventory_id integer DEFAULT nextval('pagila.inventory_inventory_id_seq'::regclass) NOT NULL,
    film_id smallint NOT NULL,
    store_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: language_language_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.language_language_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: language; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.language (
    language_id integer DEFAULT nextval('pagila.language_language_id_seq'::regclass) NOT NULL,
    name character(20) NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: nicer_but_slower_film_list; Type: VIEW; Schema: pagila; Owner: -
--

CREATE VIEW pagila.nicer_but_slower_film_list AS
 SELECT film.film_id AS fid,
    film.title,
    film.description,
    category.name AS category,
    film.rental_rate AS price,
    film.length,
    film.rating,
    pagila.group_concat((((upper("substring"((actor.first_name)::text, 1, 1)) || lower("substring"((actor.first_name)::text, 2))) || upper("substring"((actor.last_name)::text, 1, 1))) || lower("substring"((actor.last_name)::text, 2)))) AS actors
   FROM ((((pagila.category
     LEFT JOIN pagila.film_category ON ((category.category_id = film_category.category_id)))
     LEFT JOIN pagila.film ON ((film_category.film_id = film.film_id)))
     JOIN pagila.film_actor ON ((film.film_id = film_actor.film_id)))
     JOIN pagila.actor ON ((film_actor.actor_id = actor.actor_id)))
  GROUP BY film.film_id, film.title, film.description, category.name, film.rental_rate, film.length, film.rating;


--
-- Name: payment_payment_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.payment_payment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payment; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.payment (
    payment_id integer DEFAULT nextval('pagila.payment_payment_id_seq'::regclass) NOT NULL,
    customer_id smallint NOT NULL,
    staff_id smallint NOT NULL,
    rental_id integer NOT NULL,
    amount numeric(5,2) NOT NULL,
    payment_date timestamp without time zone NOT NULL
);


--
-- Name: payment_p2007_01; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.payment_p2007_01 (
    CONSTRAINT payment_p2007_01_payment_date_check CHECK (((payment_date >= '2007-01-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-02-01 00:00:00'::timestamp without time zone)))
)
INHERITS (pagila.payment);


--
-- Name: payment_p2007_02; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.payment_p2007_02 (
    CONSTRAINT payment_p2007_02_payment_date_check CHECK (((payment_date >= '2007-02-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-03-01 00:00:00'::timestamp without time zone)))
)
INHERITS (pagila.payment);


--
-- Name: payment_p2007_03; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.payment_p2007_03 (
    CONSTRAINT payment_p2007_03_payment_date_check CHECK (((payment_date >= '2007-03-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-04-01 00:00:00'::timestamp without time zone)))
)
INHERITS (pagila.payment);


--
-- Name: payment_p2007_04; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.payment_p2007_04 (
    CONSTRAINT payment_p2007_04_payment_date_check CHECK (((payment_date >= '2007-04-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-05-01 00:00:00'::timestamp without time zone)))
)
INHERITS (pagila.payment);


--
-- Name: payment_p2007_05; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.payment_p2007_05 (
    CONSTRAINT payment_p2007_05_payment_date_check CHECK (((payment_date >= '2007-05-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-06-01 00:00:00'::timestamp without time zone)))
)
INHERITS (pagila.payment);


--
-- Name: payment_p2007_06; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.payment_p2007_06 (
    CONSTRAINT payment_p2007_06_payment_date_check CHECK (((payment_date >= '2007-06-01 00:00:00'::timestamp without time zone) AND (payment_date < '2007-07-01 00:00:00'::timestamp without time zone)))
)
INHERITS (pagila.payment);


--
-- Name: rental_rental_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.rental_rental_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rental; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.rental (
    rental_id integer DEFAULT nextval('pagila.rental_rental_id_seq'::regclass) NOT NULL,
    rental_date timestamp without time zone NOT NULL,
    inventory_id integer NOT NULL,
    customer_id smallint NOT NULL,
    return_date timestamp without time zone,
    staff_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: sales_by_film_category; Type: VIEW; Schema: pagila; Owner: -
--

CREATE VIEW pagila.sales_by_film_category AS
 SELECT c.name AS category,
    sum(p.amount) AS total_sales
   FROM (((((pagila.payment p
     JOIN pagila.rental r ON ((p.rental_id = r.rental_id)))
     JOIN pagila.inventory i ON ((r.inventory_id = i.inventory_id)))
     JOIN pagila.film f ON ((i.film_id = f.film_id)))
     JOIN pagila.film_category fc ON ((f.film_id = fc.film_id)))
     JOIN pagila.category c ON ((fc.category_id = c.category_id)))
  GROUP BY c.name
  ORDER BY (sum(p.amount)) DESC;


--
-- Name: staff_staff_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.staff_staff_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: staff; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.staff (
    staff_id integer DEFAULT nextval('pagila.staff_staff_id_seq'::regclass) NOT NULL,
    first_name character varying(45) NOT NULL,
    last_name character varying(45) NOT NULL,
    address_id smallint NOT NULL,
    email character varying(50),
    store_id smallint NOT NULL,
    active boolean DEFAULT true NOT NULL,
    username character varying(16) NOT NULL,
    password character varying(40),
    last_update timestamp without time zone DEFAULT now() NOT NULL,
    picture bytea
);


--
-- Name: store_store_id_seq; Type: SEQUENCE; Schema: pagila; Owner: -
--

CREATE SEQUENCE pagila.store_store_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: store; Type: TABLE; Schema: pagila; Owner: -
--

CREATE TABLE pagila.store (
    store_id integer DEFAULT nextval('pagila.store_store_id_seq'::regclass) NOT NULL,
    manager_staff_id smallint NOT NULL,
    address_id smallint NOT NULL,
    last_update timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: sales_by_store; Type: VIEW; Schema: pagila; Owner: -
--

CREATE VIEW pagila.sales_by_store AS
 SELECT (((c.city)::text || ','::text) || (cy.country)::text) AS store,
    (((m.first_name)::text || ' '::text) || (m.last_name)::text) AS manager,
    sum(p.amount) AS total_sales
   FROM (((((((pagila.payment p
     JOIN pagila.rental r ON ((p.rental_id = r.rental_id)))
     JOIN pagila.inventory i ON ((r.inventory_id = i.inventory_id)))
     JOIN pagila.store s ON ((i.store_id = s.store_id)))
     JOIN pagila.address a ON ((s.address_id = a.address_id)))
     JOIN pagila.city c ON ((a.city_id = c.city_id)))
     JOIN pagila.country cy ON ((c.country_id = cy.country_id)))
     JOIN pagila.staff m ON ((s.manager_staff_id = m.staff_id)))
  GROUP BY cy.country, c.city, s.store_id, m.first_name, m.last_name
  ORDER BY cy.country, c.city;


--
-- Name: staff_list; Type: VIEW; Schema: pagila; Owner: -
--

CREATE VIEW pagila.staff_list AS
 SELECT s.staff_id AS id,
    (((s.first_name)::text || ' '::text) || (s.last_name)::text) AS name,
    a.address,
    a.postal_code AS "zip code",
    a.phone,
    city.city,
    country.country,
    s.store_id AS sid
   FROM (((pagila.staff s
     JOIN pagila.address a ON ((s.address_id = a.address_id)))
     JOIN pagila.city ON ((a.city_id = city.city_id)))
     JOIN pagila.country ON ((city.country_id = country.country_id)));


--
-- Name: payment_p2007_01 payment_id; Type: DEFAULT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_01 ALTER COLUMN payment_id SET DEFAULT nextval('pagila.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_02 payment_id; Type: DEFAULT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_02 ALTER COLUMN payment_id SET DEFAULT nextval('pagila.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_03 payment_id; Type: DEFAULT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_03 ALTER COLUMN payment_id SET DEFAULT nextval('pagila.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_04 payment_id; Type: DEFAULT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_04 ALTER COLUMN payment_id SET DEFAULT nextval('pagila.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_05 payment_id; Type: DEFAULT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_05 ALTER COLUMN payment_id SET DEFAULT nextval('pagila.payment_payment_id_seq'::regclass);


--
-- Name: payment_p2007_06 payment_id; Type: DEFAULT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_06 ALTER COLUMN payment_id SET DEFAULT nextval('pagila.payment_payment_id_seq'::regclass);


--
-- Name: actor actor_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.actor
    ADD CONSTRAINT actor_pkey PRIMARY KEY (actor_id);


--
-- Name: address address_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.address
    ADD CONSTRAINT address_pkey PRIMARY KEY (address_id);


--
-- Name: category category_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.category
    ADD CONSTRAINT category_pkey PRIMARY KEY (category_id);


--
-- Name: city city_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.city
    ADD CONSTRAINT city_pkey PRIMARY KEY (city_id);


--
-- Name: country country_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.country
    ADD CONSTRAINT country_pkey PRIMARY KEY (country_id);


--
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- Name: film_actor film_actor_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film_actor
    ADD CONSTRAINT film_actor_pkey PRIMARY KEY (actor_id, film_id);


--
-- Name: film_category film_category_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film_category
    ADD CONSTRAINT film_category_pkey PRIMARY KEY (film_id, category_id);


--
-- Name: film film_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film
    ADD CONSTRAINT film_pkey PRIMARY KEY (film_id);


--
-- Name: inventory inventory_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.inventory
    ADD CONSTRAINT inventory_pkey PRIMARY KEY (inventory_id);


--
-- Name: language language_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.language
    ADD CONSTRAINT language_pkey PRIMARY KEY (language_id);


--
-- Name: payment payment_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment
    ADD CONSTRAINT payment_pkey PRIMARY KEY (payment_id);


--
-- Name: rental rental_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.rental
    ADD CONSTRAINT rental_pkey PRIMARY KEY (rental_id);


--
-- Name: staff staff_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.staff
    ADD CONSTRAINT staff_pkey PRIMARY KEY (staff_id);


--
-- Name: store store_pkey; Type: CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.store
    ADD CONSTRAINT store_pkey PRIMARY KEY (store_id);


--
-- Name: film_fulltext_idx; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX film_fulltext_idx ON pagila.film USING gist (fulltext);


--
-- Name: idx_actor_last_name; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_actor_last_name ON pagila.actor USING btree (last_name);


--
-- Name: idx_fk_address_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_address_id ON pagila.customer USING btree (address_id);


--
-- Name: idx_fk_city_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_city_id ON pagila.address USING btree (city_id);


--
-- Name: idx_fk_country_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_country_id ON pagila.city USING btree (country_id);


--
-- Name: idx_fk_customer_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_customer_id ON pagila.payment USING btree (customer_id);


--
-- Name: idx_fk_film_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_film_id ON pagila.film_actor USING btree (film_id);


--
-- Name: idx_fk_inventory_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_inventory_id ON pagila.rental USING btree (inventory_id);


--
-- Name: idx_fk_language_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_language_id ON pagila.film USING btree (language_id);


--
-- Name: idx_fk_original_language_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_original_language_id ON pagila.film USING btree (original_language_id);


--
-- Name: idx_fk_payment_p2007_01_customer_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_01_customer_id ON pagila.payment_p2007_01 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_01_staff_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_01_staff_id ON pagila.payment_p2007_01 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_02_customer_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_02_customer_id ON pagila.payment_p2007_02 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_02_staff_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_02_staff_id ON pagila.payment_p2007_02 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_03_customer_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_03_customer_id ON pagila.payment_p2007_03 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_03_staff_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_03_staff_id ON pagila.payment_p2007_03 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_04_customer_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_04_customer_id ON pagila.payment_p2007_04 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_04_staff_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_04_staff_id ON pagila.payment_p2007_04 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_05_customer_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_05_customer_id ON pagila.payment_p2007_05 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_05_staff_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_05_staff_id ON pagila.payment_p2007_05 USING btree (staff_id);


--
-- Name: idx_fk_payment_p2007_06_customer_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_06_customer_id ON pagila.payment_p2007_06 USING btree (customer_id);


--
-- Name: idx_fk_payment_p2007_06_staff_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_payment_p2007_06_staff_id ON pagila.payment_p2007_06 USING btree (staff_id);


--
-- Name: idx_fk_staff_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_staff_id ON pagila.payment USING btree (staff_id);


--
-- Name: idx_fk_store_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_fk_store_id ON pagila.customer USING btree (store_id);


--
-- Name: idx_last_name; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_last_name ON pagila.customer USING btree (last_name);


--
-- Name: idx_store_id_film_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_store_id_film_id ON pagila.inventory USING btree (store_id, film_id);


--
-- Name: idx_title; Type: INDEX; Schema: pagila; Owner: -
--

CREATE INDEX idx_title ON pagila.film USING btree (title);


--
-- Name: idx_unq_manager_staff_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE UNIQUE INDEX idx_unq_manager_staff_id ON pagila.store USING btree (manager_staff_id);


--
-- Name: idx_unq_rental_rental_date_inventory_id_customer_id; Type: INDEX; Schema: pagila; Owner: -
--

CREATE UNIQUE INDEX idx_unq_rental_rental_date_inventory_id_customer_id ON pagila.rental USING btree (rental_date, inventory_id, customer_id);


--
-- Name: payment payment_insert_p2007_01; Type: RULE; Schema: pagila; Owner: -
--

CREATE RULE payment_insert_p2007_01 AS
    ON INSERT TO pagila.payment
   WHERE ((new.payment_date >= '2007-01-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-02-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO pagila.payment_p2007_01 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_02; Type: RULE; Schema: pagila; Owner: -
--

CREATE RULE payment_insert_p2007_02 AS
    ON INSERT TO pagila.payment
   WHERE ((new.payment_date >= '2007-02-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-03-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO pagila.payment_p2007_02 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_03; Type: RULE; Schema: pagila; Owner: -
--

CREATE RULE payment_insert_p2007_03 AS
    ON INSERT TO pagila.payment
   WHERE ((new.payment_date >= '2007-03-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-04-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO pagila.payment_p2007_03 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_04; Type: RULE; Schema: pagila; Owner: -
--

CREATE RULE payment_insert_p2007_04 AS
    ON INSERT TO pagila.payment
   WHERE ((new.payment_date >= '2007-04-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-05-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO pagila.payment_p2007_04 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_05; Type: RULE; Schema: pagila; Owner: -
--

CREATE RULE payment_insert_p2007_05 AS
    ON INSERT TO pagila.payment
   WHERE ((new.payment_date >= '2007-05-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-06-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO pagila.payment_p2007_05 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: payment payment_insert_p2007_06; Type: RULE; Schema: pagila; Owner: -
--

CREATE RULE payment_insert_p2007_06 AS
    ON INSERT TO pagila.payment
   WHERE ((new.payment_date >= '2007-06-01 00:00:00'::timestamp without time zone) AND (new.payment_date < '2007-07-01 00:00:00'::timestamp without time zone)) DO INSTEAD  INSERT INTO pagila.payment_p2007_06 (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  VALUES (DEFAULT, new.customer_id, new.staff_id, new.rental_id, new.amount, new.payment_date);


--
-- Name: film film_fulltext_trigger; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER film_fulltext_trigger BEFORE INSERT OR UPDATE ON pagila.film FOR EACH ROW EXECUTE FUNCTION tsvector_update_trigger('fulltext', 'pg_catalog.english', 'title', 'description');


--
-- Name: actor last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.actor FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: address last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.address FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: category last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.category FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: city last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.city FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: country last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.country FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: customer last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.customer FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: film last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.film FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: film_actor last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.film_actor FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: film_category last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.film_category FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: inventory last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.inventory FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: language last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.language FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: rental last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.rental FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: staff last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.staff FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: store last_updated; Type: TRIGGER; Schema: pagila; Owner: -
--

CREATE TRIGGER last_updated BEFORE UPDATE ON pagila.store FOR EACH ROW EXECUTE FUNCTION pagila.last_updated();


--
-- Name: address address_city_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.address
    ADD CONSTRAINT address_city_id_fkey FOREIGN KEY (city_id) REFERENCES pagila.city(city_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: city city_country_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.city
    ADD CONSTRAINT city_country_id_fkey FOREIGN KEY (country_id) REFERENCES pagila.country(country_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: customer customer_address_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.customer
    ADD CONSTRAINT customer_address_id_fkey FOREIGN KEY (address_id) REFERENCES pagila.address(address_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: customer customer_store_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.customer
    ADD CONSTRAINT customer_store_id_fkey FOREIGN KEY (store_id) REFERENCES pagila.store(store_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film_actor film_actor_actor_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film_actor
    ADD CONSTRAINT film_actor_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES pagila.actor(actor_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film_actor film_actor_film_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film_actor
    ADD CONSTRAINT film_actor_film_id_fkey FOREIGN KEY (film_id) REFERENCES pagila.film(film_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film_category film_category_category_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film_category
    ADD CONSTRAINT film_category_category_id_fkey FOREIGN KEY (category_id) REFERENCES pagila.category(category_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film_category film_category_film_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film_category
    ADD CONSTRAINT film_category_film_id_fkey FOREIGN KEY (film_id) REFERENCES pagila.film(film_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film film_language_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film
    ADD CONSTRAINT film_language_id_fkey FOREIGN KEY (language_id) REFERENCES pagila.language(language_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: film film_original_language_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.film
    ADD CONSTRAINT film_original_language_id_fkey FOREIGN KEY (original_language_id) REFERENCES pagila.language(language_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: inventory inventory_film_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.inventory
    ADD CONSTRAINT inventory_film_id_fkey FOREIGN KEY (film_id) REFERENCES pagila.film(film_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: inventory inventory_store_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.inventory
    ADD CONSTRAINT inventory_store_id_fkey FOREIGN KEY (store_id) REFERENCES pagila.store(store_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: payment payment_customer_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment
    ADD CONSTRAINT payment_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES pagila.customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: payment_p2007_01 payment_p2007_01_customer_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_01
    ADD CONSTRAINT payment_p2007_01_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES pagila.customer(customer_id);


--
-- Name: payment_p2007_01 payment_p2007_01_rental_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_01
    ADD CONSTRAINT payment_p2007_01_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES pagila.rental(rental_id);


--
-- Name: payment_p2007_01 payment_p2007_01_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_01
    ADD CONSTRAINT payment_p2007_01_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES pagila.staff(staff_id);


--
-- Name: payment_p2007_02 payment_p2007_02_customer_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_02
    ADD CONSTRAINT payment_p2007_02_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES pagila.customer(customer_id);


--
-- Name: payment_p2007_02 payment_p2007_02_rental_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_02
    ADD CONSTRAINT payment_p2007_02_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES pagila.rental(rental_id);


--
-- Name: payment_p2007_02 payment_p2007_02_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_02
    ADD CONSTRAINT payment_p2007_02_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES pagila.staff(staff_id);


--
-- Name: payment_p2007_03 payment_p2007_03_customer_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_03
    ADD CONSTRAINT payment_p2007_03_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES pagila.customer(customer_id);


--
-- Name: payment_p2007_03 payment_p2007_03_rental_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_03
    ADD CONSTRAINT payment_p2007_03_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES pagila.rental(rental_id);


--
-- Name: payment_p2007_03 payment_p2007_03_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_03
    ADD CONSTRAINT payment_p2007_03_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES pagila.staff(staff_id);


--
-- Name: payment_p2007_04 payment_p2007_04_customer_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_04
    ADD CONSTRAINT payment_p2007_04_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES pagila.customer(customer_id);


--
-- Name: payment_p2007_04 payment_p2007_04_rental_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_04
    ADD CONSTRAINT payment_p2007_04_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES pagila.rental(rental_id);


--
-- Name: payment_p2007_04 payment_p2007_04_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_04
    ADD CONSTRAINT payment_p2007_04_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES pagila.staff(staff_id);


--
-- Name: payment_p2007_05 payment_p2007_05_customer_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_05
    ADD CONSTRAINT payment_p2007_05_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES pagila.customer(customer_id);


--
-- Name: payment_p2007_05 payment_p2007_05_rental_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_05
    ADD CONSTRAINT payment_p2007_05_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES pagila.rental(rental_id);


--
-- Name: payment_p2007_05 payment_p2007_05_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_05
    ADD CONSTRAINT payment_p2007_05_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES pagila.staff(staff_id);


--
-- Name: payment_p2007_06 payment_p2007_06_customer_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_06
    ADD CONSTRAINT payment_p2007_06_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES pagila.customer(customer_id);


--
-- Name: payment_p2007_06 payment_p2007_06_rental_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_06
    ADD CONSTRAINT payment_p2007_06_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES pagila.rental(rental_id);


--
-- Name: payment_p2007_06 payment_p2007_06_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment_p2007_06
    ADD CONSTRAINT payment_p2007_06_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES pagila.staff(staff_id);


--
-- Name: payment payment_rental_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment
    ADD CONSTRAINT payment_rental_id_fkey FOREIGN KEY (rental_id) REFERENCES pagila.rental(rental_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: payment payment_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.payment
    ADD CONSTRAINT payment_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES pagila.staff(staff_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: rental rental_customer_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.rental
    ADD CONSTRAINT rental_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES pagila.customer(customer_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: rental rental_inventory_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.rental
    ADD CONSTRAINT rental_inventory_id_fkey FOREIGN KEY (inventory_id) REFERENCES pagila.inventory(inventory_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: rental rental_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.rental
    ADD CONSTRAINT rental_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES pagila.staff(staff_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: staff staff_address_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.staff
    ADD CONSTRAINT staff_address_id_fkey FOREIGN KEY (address_id) REFERENCES pagila.address(address_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: staff staff_store_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.staff
    ADD CONSTRAINT staff_store_id_fkey FOREIGN KEY (store_id) REFERENCES pagila.store(store_id);


--
-- Name: store store_address_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.store
    ADD CONSTRAINT store_address_id_fkey FOREIGN KEY (address_id) REFERENCES pagila.address(address_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: store store_manager_staff_id_fkey; Type: FK CONSTRAINT; Schema: pagila; Owner: -
--

ALTER TABLE ONLY pagila.store
    ADD CONSTRAINT store_manager_staff_id_fkey FOREIGN KEY (manager_staff_id) REFERENCES pagila.staff(staff_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: SCHEMA pagila; Type: ACL; Schema: -; Owner: -
--

GRANT ALL ON SCHEMA pagila TO schmitz;
GRANT USAGE ON SCHEMA pagila TO enseignant;
GRANT USAGE ON SCHEMA pagila TO etudiant;


--
-- Name: TABLE customer; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.customer TO etudiant;


--
-- Name: TABLE category; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.category TO etudiant;


--
-- Name: TABLE film_category; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.film_category TO etudiant;


--
-- Name: TABLE actor; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.actor TO etudiant;


--
-- Name: TABLE film; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.film TO etudiant;


--
-- Name: TABLE film_actor; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.film_actor TO etudiant;


--
-- Name: TABLE actor_info; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.actor_info TO etudiant;


--
-- Name: TABLE address; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.address TO etudiant;


--
-- Name: TABLE city; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.city TO etudiant;


--
-- Name: TABLE country; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.country TO etudiant;


--
-- Name: TABLE customer_list; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.customer_list TO etudiant;


--
-- Name: TABLE film_list; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.film_list TO etudiant;


--
-- Name: TABLE inventory; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.inventory TO etudiant;


--
-- Name: TABLE language; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.language TO etudiant;


--
-- Name: TABLE nicer_but_slower_film_list; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.nicer_but_slower_film_list TO etudiant;


--
-- Name: TABLE payment; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.payment TO etudiant;


--
-- Name: TABLE payment_p2007_01; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.payment_p2007_01 TO etudiant;


--
-- Name: TABLE payment_p2007_02; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.payment_p2007_02 TO etudiant;


--
-- Name: TABLE payment_p2007_03; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.payment_p2007_03 TO etudiant;


--
-- Name: TABLE payment_p2007_04; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.payment_p2007_04 TO etudiant;


--
-- Name: TABLE payment_p2007_05; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.payment_p2007_05 TO etudiant;


--
-- Name: TABLE payment_p2007_06; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.payment_p2007_06 TO etudiant;


--
-- Name: TABLE rental; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.rental TO etudiant;


--
-- Name: TABLE sales_by_film_category; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.sales_by_film_category TO etudiant;


--
-- Name: TABLE staff; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.staff TO etudiant;


--
-- Name: TABLE store; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.store TO etudiant;


--
-- Name: TABLE sales_by_store; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.sales_by_store TO etudiant;


--
-- Name: TABLE staff_list; Type: ACL; Schema: pagila; Owner: -
--

GRANT SELECT ON TABLE pagila.staff_list TO etudiant;


--
-- PostgreSQL database dump complete
--


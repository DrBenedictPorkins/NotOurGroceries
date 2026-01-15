#!/usr/bin/env python3
"""Seed the Product table with common grocery items."""

import boto3
import uuid
from datetime import datetime

# Initialize DynamoDB client
session = boto3.Session(profile_name='mine')
dynamodb = session.resource('dynamodb', region_name='us-east-1')
table = dynamodb.Table('Product-nktezw3d6vcl5jbk7n44jku4e4-NONE')

def normalize_name(name: str) -> str:
    """Normalize product name for matching."""
    return name.lower().strip()

# Common grocery products organized by category
PRODUCTS = [
    # DAIRY
    {"name": "Milk", "category": "Dairy", "aliases": ["whole milk", "2% milk", "skim milk", "milks"]},
    {"name": "Eggs", "category": "Dairy", "aliases": ["egg", "dozen eggs", "large eggs"]},
    {"name": "Butter", "category": "Dairy", "aliases": ["unsalted butter", "salted butter"]},
    {"name": "Cheese", "category": "Dairy", "aliases": ["cheddar", "mozzarella", "swiss cheese", "cheeses"]},
    {"name": "Yogurt", "category": "Dairy", "aliases": ["greek yogurt", "yoghurt", "yogurts"]},
    {"name": "Cream Cheese", "category": "Dairy", "aliases": ["philadelphia"]},
    {"name": "Sour Cream", "category": "Dairy", "aliases": ["sourcream"]},
    {"name": "Heavy Cream", "category": "Dairy", "aliases": ["whipping cream", "heavy whipping cream"]},
    {"name": "Half and Half", "category": "Dairy", "aliases": ["half & half", "coffee cream"]},
    {"name": "Cottage Cheese", "category": "Dairy", "aliases": []},
    {"name": "Parmesan", "category": "Dairy", "aliases": ["parmesan cheese", "parmigiano"]},
    {"name": "Feta Cheese", "category": "Dairy", "aliases": ["feta"]},
    {"name": "Ricotta", "category": "Dairy", "aliases": ["ricotta cheese"]},
    {"name": "Oat Milk", "category": "Dairy", "aliases": ["oatmilk", "oat milk"]},
    {"name": "Almond Milk", "category": "Dairy", "aliases": ["almondmilk"]},
    {"name": "Soy Milk", "category": "Dairy", "aliases": ["soymilk"]},

    # BREAD & BAKERY
    {"name": "Bread", "category": "Bread & Bakery", "aliases": ["loaf", "white bread", "wheat bread", "breads"]},
    {"name": "Bagels", "category": "Bread & Bakery", "aliases": ["bagel", "everything bagel"]},
    {"name": "English Muffins", "category": "Bread & Bakery", "aliases": ["english muffin"]},
    {"name": "Tortillas", "category": "Bread & Bakery", "aliases": ["tortilla", "flour tortillas", "corn tortillas"]},
    {"name": "Pita Bread", "category": "Bread & Bakery", "aliases": ["pita", "pitas"]},
    {"name": "Croissants", "category": "Bread & Bakery", "aliases": ["croissant"]},
    {"name": "Hamburger Buns", "category": "Bread & Bakery", "aliases": ["burger buns", "buns"]},
    {"name": "Hot Dog Buns", "category": "Bread & Bakery", "aliases": ["hotdog buns"]},
    {"name": "Rolls", "category": "Bread & Bakery", "aliases": ["dinner rolls", "roll"]},
    {"name": "Muffins", "category": "Bread & Bakery", "aliases": ["muffin", "blueberry muffins"]},
    {"name": "Donuts", "category": "Bread & Bakery", "aliases": ["donut", "doughnuts", "doughnut"]},

    # PRODUCE - FRUITS
    {"name": "Apples", "category": "Produce", "aliases": ["apple", "fuji apples", "gala apples", "honeycrisp"]},
    {"name": "Bananas", "category": "Produce", "aliases": ["banana"]},
    {"name": "Oranges", "category": "Produce", "aliases": ["orange", "navel oranges"]},
    {"name": "Lemons", "category": "Produce", "aliases": ["lemon"]},
    {"name": "Limes", "category": "Produce", "aliases": ["lime"]},
    {"name": "Grapes", "category": "Produce", "aliases": ["grape", "red grapes", "green grapes"]},
    {"name": "Strawberries", "category": "Produce", "aliases": ["strawberry"]},
    {"name": "Blueberries", "category": "Produce", "aliases": ["blueberry"]},
    {"name": "Raspberries", "category": "Produce", "aliases": ["raspberry"]},
    {"name": "Blackberries", "category": "Produce", "aliases": ["blackberry"]},
    {"name": "Avocados", "category": "Produce", "aliases": ["avocado"]},
    {"name": "Watermelon", "category": "Produce", "aliases": ["watermelons"]},
    {"name": "Cantaloupe", "category": "Produce", "aliases": ["cantaloupes"]},
    {"name": "Peaches", "category": "Produce", "aliases": ["peach"]},
    {"name": "Pears", "category": "Produce", "aliases": ["pear"]},
    {"name": "Mangoes", "category": "Produce", "aliases": ["mango"]},
    {"name": "Pineapple", "category": "Produce", "aliases": ["pineapples"]},
    {"name": "Cherries", "category": "Produce", "aliases": ["cherry"]},
    {"name": "Kiwi", "category": "Produce", "aliases": ["kiwis", "kiwifruit"]},
    {"name": "Grapefruit", "category": "Produce", "aliases": ["grapefruits"]},
    {"name": "Pomegranate", "category": "Produce", "aliases": ["pomegranates"]},
    {"name": "Plums", "category": "Produce", "aliases": ["plum"]},

    # PRODUCE - VEGETABLES
    {"name": "Onions", "category": "Produce", "aliases": ["onion", "yellow onion", "white onion", "red onion"]},
    {"name": "Garlic", "category": "Produce", "aliases": ["garlic cloves", "fresh garlic"]},
    {"name": "Tomatoes", "category": "Produce", "aliases": ["tomato", "cherry tomatoes", "roma tomatoes"]},
    {"name": "Potatoes", "category": "Produce", "aliases": ["potato", "russet potatoes", "yukon gold"]},
    {"name": "Carrots", "category": "Produce", "aliases": ["carrot", "baby carrots"]},
    {"name": "Celery", "category": "Produce", "aliases": ["celery sticks", "celery stalks"]},
    {"name": "Lettuce", "category": "Produce", "aliases": ["romaine", "iceberg lettuce"]},
    {"name": "Spinach", "category": "Produce", "aliases": ["baby spinach", "fresh spinach"]},
    {"name": "Kale", "category": "Produce", "aliases": ["baby kale"]},
    {"name": "Broccoli", "category": "Produce", "aliases": ["broccoli florets"]},
    {"name": "Cauliflower", "category": "Produce", "aliases": []},
    {"name": "Bell Peppers", "category": "Produce", "aliases": ["bell pepper", "red pepper", "green pepper", "peppers"]},
    {"name": "Cucumbers", "category": "Produce", "aliases": ["cucumber"]},
    {"name": "Zucchini", "category": "Produce", "aliases": ["zucchinis"]},
    {"name": "Mushrooms", "category": "Produce", "aliases": ["mushroom", "button mushrooms", "cremini"]},
    {"name": "Green Beans", "category": "Produce", "aliases": ["string beans", "green bean"]},
    {"name": "Asparagus", "category": "Produce", "aliases": []},
    {"name": "Corn", "category": "Produce", "aliases": ["corn on the cob", "sweet corn"]},
    {"name": "Cabbage", "category": "Produce", "aliases": ["green cabbage", "red cabbage"]},
    {"name": "Brussels Sprouts", "category": "Produce", "aliases": ["brussel sprouts", "brussels"]},
    {"name": "Sweet Potatoes", "category": "Produce", "aliases": ["sweet potato", "yams"]},
    {"name": "Ginger", "category": "Produce", "aliases": ["fresh ginger", "ginger root"]},
    {"name": "Jalapeños", "category": "Produce", "aliases": ["jalapeno", "jalapenos"]},
    {"name": "Cilantro", "category": "Produce", "aliases": ["fresh cilantro", "coriander"]},
    {"name": "Parsley", "category": "Produce", "aliases": ["fresh parsley"]},
    {"name": "Basil", "category": "Produce", "aliases": ["fresh basil"]},
    {"name": "Green Onions", "category": "Produce", "aliases": ["scallions", "spring onions"]},
    {"name": "Shallots", "category": "Produce", "aliases": ["shallot"]},
    {"name": "Eggplant", "category": "Produce", "aliases": ["aubergine"]},
    {"name": "Artichokes", "category": "Produce", "aliases": ["artichoke"]},
    {"name": "Radishes", "category": "Produce", "aliases": ["radish"]},
    {"name": "Beets", "category": "Produce", "aliases": ["beet", "beetroot"]},
    {"name": "Arugula", "category": "Produce", "aliases": ["rocket"]},
    {"name": "Mixed Greens", "category": "Produce", "aliases": ["salad mix", "spring mix"]},

    # MEAT & SEAFOOD
    {"name": "Chicken Breast", "category": "Meat & Seafood", "aliases": ["chicken breasts", "boneless chicken"]},
    {"name": "Chicken Thighs", "category": "Meat & Seafood", "aliases": ["chicken thigh"]},
    {"name": "Ground Beef", "category": "Meat & Seafood", "aliases": ["hamburger meat", "minced beef"]},
    {"name": "Ground Turkey", "category": "Meat & Seafood", "aliases": ["turkey mince"]},
    {"name": "Bacon", "category": "Meat & Seafood", "aliases": ["turkey bacon"]},
    {"name": "Sausage", "category": "Meat & Seafood", "aliases": ["sausages", "italian sausage", "breakfast sausage"]},
    {"name": "Pork Chops", "category": "Meat & Seafood", "aliases": ["pork chop"]},
    {"name": "Pork Tenderloin", "category": "Meat & Seafood", "aliases": []},
    {"name": "Ham", "category": "Meat & Seafood", "aliases": ["deli ham", "sliced ham"]},
    {"name": "Steak", "category": "Meat & Seafood", "aliases": ["steaks", "ribeye", "sirloin", "ny strip"]},
    {"name": "Salmon", "category": "Meat & Seafood", "aliases": ["salmon fillet", "atlantic salmon"]},
    {"name": "Shrimp", "category": "Meat & Seafood", "aliases": ["prawns", "frozen shrimp"]},
    {"name": "Tilapia", "category": "Meat & Seafood", "aliases": []},
    {"name": "Tuna", "category": "Meat & Seafood", "aliases": ["ahi tuna", "tuna steak"]},
    {"name": "Cod", "category": "Meat & Seafood", "aliases": ["cod fillet"]},
    {"name": "Hot Dogs", "category": "Meat & Seafood", "aliases": ["hotdogs", "franks", "weiners"]},
    {"name": "Deli Turkey", "category": "Meat & Seafood", "aliases": ["turkey slices", "sliced turkey"]},
    {"name": "Rotisserie Chicken", "category": "Meat & Seafood", "aliases": ["whole chicken"]},

    # PANTRY - CANNED GOODS
    {"name": "Canned Tomatoes", "category": "Pantry", "aliases": ["diced tomatoes", "crushed tomatoes", "tomato sauce"]},
    {"name": "Canned Beans", "category": "Pantry", "aliases": ["black beans", "kidney beans", "pinto beans", "chickpeas", "garbanzo beans"]},
    {"name": "Canned Corn", "category": "Pantry", "aliases": []},
    {"name": "Canned Tuna", "category": "Pantry", "aliases": ["tuna fish"]},
    {"name": "Canned Chicken", "category": "Pantry", "aliases": []},
    {"name": "Soup", "category": "Pantry", "aliases": ["chicken soup", "tomato soup", "soups"]},
    {"name": "Broth", "category": "Pantry", "aliases": ["chicken broth", "beef broth", "vegetable broth", "stock"]},
    {"name": "Coconut Milk", "category": "Pantry", "aliases": ["canned coconut milk"]},

    # PANTRY - PASTA & GRAINS
    {"name": "Pasta", "category": "Pantry", "aliases": ["spaghetti", "penne", "linguine", "fettuccine", "noodles"]},
    {"name": "Rice", "category": "Pantry", "aliases": ["white rice", "brown rice", "jasmine rice", "basmati"]},
    {"name": "Quinoa", "category": "Pantry", "aliases": []},
    {"name": "Oatmeal", "category": "Pantry", "aliases": ["oats", "rolled oats", "instant oatmeal"]},
    {"name": "Cereal", "category": "Pantry", "aliases": ["cereals", "breakfast cereal"]},
    {"name": "Granola", "category": "Pantry", "aliases": []},
    {"name": "Flour", "category": "Pantry", "aliases": ["all purpose flour", "bread flour", "whole wheat flour"]},
    {"name": "Sugar", "category": "Pantry", "aliases": ["white sugar", "granulated sugar"]},
    {"name": "Brown Sugar", "category": "Pantry", "aliases": []},
    {"name": "Powdered Sugar", "category": "Pantry", "aliases": ["confectioners sugar", "icing sugar"]},
    {"name": "Breadcrumbs", "category": "Pantry", "aliases": ["panko", "bread crumbs"]},
    {"name": "Couscous", "category": "Pantry", "aliases": []},

    # PANTRY - CONDIMENTS & SAUCES
    {"name": "Ketchup", "category": "Pantry", "aliases": ["catsup"]},
    {"name": "Mustard", "category": "Pantry", "aliases": ["yellow mustard", "dijon mustard"]},
    {"name": "Mayonnaise", "category": "Pantry", "aliases": ["mayo"]},
    {"name": "Soy Sauce", "category": "Pantry", "aliases": ["shoyu"]},
    {"name": "Hot Sauce", "category": "Pantry", "aliases": ["sriracha", "tabasco"]},
    {"name": "BBQ Sauce", "category": "Pantry", "aliases": ["barbecue sauce"]},
    {"name": "Salsa", "category": "Pantry", "aliases": []},
    {"name": "Pasta Sauce", "category": "Pantry", "aliases": ["marinara", "spaghetti sauce", "tomato sauce"]},
    {"name": "Olive Oil", "category": "Pantry", "aliases": ["extra virgin olive oil", "evoo"]},
    {"name": "Vegetable Oil", "category": "Pantry", "aliases": ["cooking oil", "canola oil"]},
    {"name": "Vinegar", "category": "Pantry", "aliases": ["white vinegar", "apple cider vinegar", "balsamic vinegar"]},
    {"name": "Honey", "category": "Pantry", "aliases": []},
    {"name": "Maple Syrup", "category": "Pantry", "aliases": ["syrup"]},
    {"name": "Peanut Butter", "category": "Pantry", "aliases": ["pb"]},
    {"name": "Jelly", "category": "Pantry", "aliases": ["jam", "grape jelly", "strawberry jam"]},
    {"name": "Salad Dressing", "category": "Pantry", "aliases": ["ranch dressing", "italian dressing", "dressing"]},
    {"name": "Worcestershire Sauce", "category": "Pantry", "aliases": []},
    {"name": "Teriyaki Sauce", "category": "Pantry", "aliases": []},
    {"name": "Fish Sauce", "category": "Pantry", "aliases": []},
    {"name": "Tahini", "category": "Pantry", "aliases": []},
    {"name": "Hummus", "category": "Pantry", "aliases": []},

    # PANTRY - BAKING
    {"name": "Baking Soda", "category": "Pantry", "aliases": ["bicarbonate of soda"]},
    {"name": "Baking Powder", "category": "Pantry", "aliases": []},
    {"name": "Vanilla Extract", "category": "Pantry", "aliases": ["vanilla"]},
    {"name": "Chocolate Chips", "category": "Pantry", "aliases": []},
    {"name": "Cocoa Powder", "category": "Pantry", "aliases": ["cocoa"]},
    {"name": "Yeast", "category": "Pantry", "aliases": ["active dry yeast", "instant yeast"]},
    {"name": "Cornstarch", "category": "Pantry", "aliases": ["corn starch"]},

    # PANTRY - SPICES
    {"name": "Salt", "category": "Pantry", "aliases": ["table salt", "sea salt", "kosher salt"]},
    {"name": "Black Pepper", "category": "Pantry", "aliases": ["pepper", "ground pepper"]},
    {"name": "Garlic Powder", "category": "Pantry", "aliases": []},
    {"name": "Onion Powder", "category": "Pantry", "aliases": []},
    {"name": "Paprika", "category": "Pantry", "aliases": ["smoked paprika"]},
    {"name": "Cumin", "category": "Pantry", "aliases": ["ground cumin"]},
    {"name": "Chili Powder", "category": "Pantry", "aliases": []},
    {"name": "Italian Seasoning", "category": "Pantry", "aliases": []},
    {"name": "Cinnamon", "category": "Pantry", "aliases": ["ground cinnamon"]},
    {"name": "Oregano", "category": "Pantry", "aliases": ["dried oregano"]},
    {"name": "Basil", "category": "Pantry", "aliases": ["dried basil"]},
    {"name": "Thyme", "category": "Pantry", "aliases": ["dried thyme"]},
    {"name": "Rosemary", "category": "Pantry", "aliases": ["dried rosemary"]},
    {"name": "Bay Leaves", "category": "Pantry", "aliases": ["bay leaf"]},
    {"name": "Cayenne Pepper", "category": "Pantry", "aliases": ["cayenne"]},
    {"name": "Nutmeg", "category": "Pantry", "aliases": []},
    {"name": "Turmeric", "category": "Pantry", "aliases": []},
    {"name": "Curry Powder", "category": "Pantry", "aliases": []},
    {"name": "Red Pepper Flakes", "category": "Pantry", "aliases": ["crushed red pepper"]},

    # SNACKS
    {"name": "Chips", "category": "Snacks", "aliases": ["potato chips", "tortilla chips"]},
    {"name": "Crackers", "category": "Snacks", "aliases": ["saltines", "ritz crackers"]},
    {"name": "Popcorn", "category": "Snacks", "aliases": ["microwave popcorn"]},
    {"name": "Pretzels", "category": "Snacks", "aliases": ["pretzel"]},
    {"name": "Nuts", "category": "Snacks", "aliases": ["almonds", "cashews", "peanuts", "mixed nuts", "walnuts"]},
    {"name": "Trail Mix", "category": "Snacks", "aliases": []},
    {"name": "Cookies", "category": "Snacks", "aliases": ["cookie", "oreos"]},
    {"name": "Granola Bars", "category": "Snacks", "aliases": ["granola bar", "protein bars"]},
    {"name": "Dried Fruit", "category": "Snacks", "aliases": ["raisins", "dried cranberries"]},
    {"name": "Fruit Snacks", "category": "Snacks", "aliases": []},

    # FROZEN
    {"name": "Ice Cream", "category": "Frozen", "aliases": ["icecream"]},
    {"name": "Frozen Pizza", "category": "Frozen", "aliases": ["pizza"]},
    {"name": "Frozen Vegetables", "category": "Frozen", "aliases": ["frozen peas", "frozen corn", "frozen broccoli"]},
    {"name": "Frozen Fruit", "category": "Frozen", "aliases": ["frozen berries", "frozen strawberries"]},
    {"name": "Frozen Waffles", "category": "Frozen", "aliases": ["waffles", "eggo"]},
    {"name": "Frozen Fries", "category": "Frozen", "aliases": ["french fries", "frozen french fries", "tater tots"]},
    {"name": "Frozen Chicken", "category": "Frozen", "aliases": ["chicken nuggets", "chicken tenders"]},
    {"name": "Ice", "category": "Frozen", "aliases": ["bag of ice", "ice cubes"]},

    # BEVERAGES
    {"name": "Coffee", "category": "Beverages", "aliases": ["ground coffee", "coffee beans"]},
    {"name": "Tea", "category": "Beverages", "aliases": ["tea bags", "green tea", "black tea"]},
    {"name": "Orange Juice", "category": "Beverages", "aliases": ["oj", "fresh squeezed"]},
    {"name": "Apple Juice", "category": "Beverages", "aliases": []},
    {"name": "Soda", "category": "Beverages", "aliases": ["coke", "cola", "sprite", "soft drinks"]},
    {"name": "Water", "category": "Beverages", "aliases": ["bottled water", "sparkling water", "seltzer"]},
    {"name": "Beer", "category": "Beverages", "aliases": ["beers"]},
    {"name": "Wine", "category": "Beverages", "aliases": ["red wine", "white wine"]},
    {"name": "Juice", "category": "Beverages", "aliases": ["fruit juice"]},
    {"name": "Sports Drinks", "category": "Beverages", "aliases": ["gatorade", "powerade"]},
    {"name": "Energy Drinks", "category": "Beverages", "aliases": ["red bull", "monster"]},
    {"name": "Lemonade", "category": "Beverages", "aliases": []},

    # HOUSEHOLD
    {"name": "Paper Towels", "category": "Household", "aliases": ["paper towel"]},
    {"name": "Toilet Paper", "category": "Household", "aliases": ["tp", "bathroom tissue"]},
    {"name": "Tissues", "category": "Household", "aliases": ["kleenex", "facial tissue"]},
    {"name": "Dish Soap", "category": "Household", "aliases": ["dish detergent", "dishwashing liquid"]},
    {"name": "Laundry Detergent", "category": "Household", "aliases": ["laundry soap"]},
    {"name": "Trash Bags", "category": "Household", "aliases": ["garbage bags"]},
    {"name": "Aluminum Foil", "category": "Household", "aliases": ["foil", "tin foil"]},
    {"name": "Plastic Wrap", "category": "Household", "aliases": ["saran wrap", "cling wrap"]},
    {"name": "Ziplock Bags", "category": "Household", "aliases": ["ziploc", "storage bags", "freezer bags"]},
    {"name": "Sponges", "category": "Household", "aliases": ["sponge", "dish sponge"]},
    {"name": "All-Purpose Cleaner", "category": "Household", "aliases": ["cleaner", "spray cleaner"]},
    {"name": "Hand Soap", "category": "Household", "aliases": []},
    {"name": "Napkins", "category": "Household", "aliases": ["paper napkins"]},
    {"name": "Paper Plates", "category": "Household", "aliases": []},
    {"name": "Plastic Cups", "category": "Household", "aliases": ["disposable cups"]},
    {"name": "Batteries", "category": "Household", "aliases": ["aa batteries", "aaa batteries"]},
    {"name": "Light Bulbs", "category": "Household", "aliases": ["lightbulbs", "bulbs"]},

    # PERSONAL CARE
    {"name": "Shampoo", "category": "Personal Care", "aliases": []},
    {"name": "Conditioner", "category": "Personal Care", "aliases": ["hair conditioner"]},
    {"name": "Body Wash", "category": "Personal Care", "aliases": ["shower gel"]},
    {"name": "Soap", "category": "Personal Care", "aliases": ["bar soap"]},
    {"name": "Toothpaste", "category": "Personal Care", "aliases": []},
    {"name": "Toothbrush", "category": "Personal Care", "aliases": ["toothbrushes"]},
    {"name": "Deodorant", "category": "Personal Care", "aliases": ["antiperspirant"]},
    {"name": "Razor", "category": "Personal Care", "aliases": ["razors", "razor blades"]},
    {"name": "Shaving Cream", "category": "Personal Care", "aliases": []},
    {"name": "Lotion", "category": "Personal Care", "aliases": ["body lotion", "moisturizer"]},
    {"name": "Sunscreen", "category": "Personal Care", "aliases": ["sunblock"]},
    {"name": "Floss", "category": "Personal Care", "aliases": ["dental floss"]},
    {"name": "Mouthwash", "category": "Personal Care", "aliases": []},
    {"name": "Cotton Balls", "category": "Personal Care", "aliases": []},
    {"name": "Q-Tips", "category": "Personal Care", "aliases": ["cotton swabs"]},
    {"name": "Band-Aids", "category": "Personal Care", "aliases": ["bandages", "bandaids"]},

    # BABY
    {"name": "Diapers", "category": "Baby", "aliases": ["diaper", "nappies"]},
    {"name": "Baby Wipes", "category": "Baby", "aliases": ["wipes"]},
    {"name": "Baby Formula", "category": "Baby", "aliases": ["formula", "infant formula"]},
    {"name": "Baby Food", "category": "Baby", "aliases": []},

    # PET
    {"name": "Dog Food", "category": "Pet", "aliases": ["kibble"]},
    {"name": "Cat Food", "category": "Pet", "aliases": []},
    {"name": "Cat Litter", "category": "Pet", "aliases": ["kitty litter"]},
    {"name": "Pet Treats", "category": "Pet", "aliases": ["dog treats", "cat treats"]},
]

def seed_products():
    """Insert all products into DynamoDB."""
    now = datetime.utcnow().isoformat() + 'Z'

    count = 0
    for product in PRODUCTS:
        item = {
            'id': str(uuid.uuid4()),
            'name': product['name'],
            'normalizedName': normalize_name(product['name']),
            'category': product['category'],
            'aliases': product['aliases'] if product['aliases'] else None,
            'createdAt': now,
            'updatedAt': now,
            '__typename': 'Product',
        }

        # Remove None values
        item = {k: v for k, v in item.items() if v is not None}

        try:
            table.put_item(Item=item)
            count += 1
            print(f"✓ Added: {product['name']}")
        except Exception as e:
            print(f"✗ Failed to add {product['name']}: {e}")

    print(f"\n✅ Seeded {count} products")

if __name__ == '__main__':
    seed_products()

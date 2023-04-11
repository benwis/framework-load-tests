use goose::prelude::*;
use goose_eggs::{validate_and_load_static_assets, Validate, validate_page};

async fn loadtest_index(user: &mut GooseUser) -> TransactionResult {
    let goose = user.get("").await?;

    let validate = &Validate::builder()
    .status(200)
    .text("benwis")
    .build();

    validate_page(user, goose, &validate).await?;

    Ok(())
}

async fn loadtest_posts(user: &mut GooseUser) -> TransactionResult {
    let goose = user.get("posts").await?;

    let validate = &Validate::builder()
    .status(200)
    .text("Posts")
    .build();

    validate_page(user, goose, &validate).await?;

    Ok(())
}

// async fn loadtest_post(user: &mut GooseUser) -> TransactionResult {
//     let goose = user.get("posts/bridging-the-divide").await?;

//     let validate = &Validate::builder()
//     .status(200)
//     .text("Bridging")
//     .build();

//     validate_and_load_static_assets(user, goose, &validate).await?;

//     Ok(())
// }


#[tokio::main]
async fn main() -> Result<(), GooseError> {
    GooseAttack::initialize()?
        .register_scenario(scenario!("HomePage")
            .register_transaction(transaction!(loadtest_index))
            // .register_transaction(transaction!(loadtest_posts))
            // .register_transaction(transaction!(loadtest_post))

        )
        .execute()
        .await?;

    Ok(())
}
